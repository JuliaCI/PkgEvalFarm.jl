# Unit tests for the sealing machinery that need no AWS (see moto.jl for the
# integration side).

module SealTests

using Test
using PkgEvalFarm
using TOML

const PEF = PkgEvalFarm

@testset "seal fingerprint" begin
    base = Dict("name" => "primary", "julia" => "JuliaLang/julia#abc",
                "buildflags" => ["LLVM_ASSERTIONS=1"])
    fp = PEF.seal_fingerprint(base)
    @test length(fp) == 16
    # scheduling/observation-only fields don't fragment the cache
    @test PEF.seal_fingerprint(merge(base, Dict("name" => "against"))) == fp
    @test PEF.seal_fingerprint(merge(base, Dict("time_limit" => 99.0))) == fp
    @test PEF.seal_fingerprint(merge(base, Dict("rr" => "RREnabled"))) == fp
    # compilecache-relevant fields do
    @test PEF.seal_fingerprint(merge(base, Dict("julia" => "v1.12.0"))) != fp
    @test PEF.seal_fingerprint(merge(base, Dict("julia_args" => ["--check-bounds=no"]))) != fp
    @test PEF.seal_run_id(fp) == "seal-$fp"
end

@testset "topological publish order" begin
    graph = Dict("A" => String[], "B" => ["A"], "C" => ["A", "B"])
    order = PEF.topo_order(["C", "B", "A"], graph)
    @test findfirst(==("A"), order) < findfirst(==("B"), order) < findfirst(==("C"), order)
    # nodes without graph entries (extension cache dirs) sort last
    order = PEF.topo_order(["AExt", "A"], Dict("A" => String[]))
    @test order == ["A", "AExt"]
    # a cycle still yields every node (publish anyway; taint covers the rest)
    order = PEF.topo_order(["X", "Y"], Dict("X" => ["Y"], "Y" => ["X"]))
    @test sort(order) == ["X", "Y"]
end

@testset "registry dependency graph" begin
    mktempdir() do reg
        mkpath(joinpath(reg, "J", "JSON"))
        mkpath(joinpath(reg, "C", "Crayons"))
        write(joinpath(reg, "Registry.toml"), """
            [packages]
            aaaaaaaa-0000-0000-0000-000000000001 = { name = "Example", path = "E/Example" }
            aaaaaaaa-0000-0000-0000-000000000002 = { name = "Crayons", path = "C/Crayons" }
            aaaaaaaa-0000-0000-0000-000000000003 = { name = "JSON", path = "J/JSON" }
            """)
        # union across version-range sections, restricted to the wanted set
        write(joinpath(reg, "J", "JSON", "Deps.toml"), """
            ["0-1"]
            Crayons = "aaaaaaaa-0000-0000-0000-000000000002"
            Unicode = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
            ["2"]
            Example = "aaaaaaaa-0000-0000-0000-000000000001"
            """)
        wanted = Set(["Example", "Crayons", "JSON"])
        graph = PEF.registry_dep_graph(reg, wanted)
        @test graph["JSON"] == ["Crayons", "Example"]   # Unicode not in the run set
        @test graph["Crayons"] == String[]              # no Deps.toml
        @test graph["Example"] == String[]              # not even a package dir

        # learned edges merge in (and are clipped to the run set)
        merged = PEF.seal_dep_graph(reg, sort(collect(wanted)),
                                    Dict("Crayons" => ["Example", "NotInRun"]))
        @test merged["Crayons"] == ["Example"]
        @test merged["JSON"] == ["Crayons", "Example"]
    end
end

@testset "parse_seal_export" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "compiled", "v1.13", "JSON"))
        mkpath(joinpath(dir, "compiled", "v1.13", "Crayons"))
        write(joinpath(dir, "compiled", "v1.13", "JSON", "JSON_abc.ji"), "ji")
        write(joinpath(dir, "compiled", "v1.13", "JSON", "JSON_abc.so"), "so")
        write(joinpath(dir, "compiled", "v1.13", "Crayons", "Crayons_def.ji"), "ji")
        open(joinpath(dir, "seal_graph.toml"), "w") do io
            TOML.print(io, Dict(
                "JSON" => Dict("uuid" => "u1", "version" => "1.0.0", "deps" => ["Crayons"]),
                "Crayons" => Dict("uuid" => "u2", "version" => "4.1.0", "deps" => String[])))
        end
        graph, files = PEF.parse_seal_export(dir)
        @test graph == Dict("JSON" => ["Crayons"], "Crayons" => String[])
        @test sort(files["JSON"]) == ["v1.13/JSON/JSON_abc.ji", "v1.13/JSON/JSON_abc.so"]
        @test files["Crayons"] == ["v1.13/Crayons/Crayons_def.ji"]
    end
    # an empty export parses to empty results (trivially-sealed stdlib case)
    mktempdir() do dir
        graph, files = PEF.parse_seal_export(dir)
        @test isempty(graph) && isempty(files)
    end
end

@testset "materialize hardlinks" begin
    mktempdir() do dir
        cache = joinpath(dir, "cache")
        withenv("PKGEVAL_SEAL_CACHE" => cache) do
            src = joinpath(cache, "sid", "files", "v1.13", "Foo")
            mkpath(src)
            write(joinpath(src, "Foo_x.ji"), "content")
            dest = joinpath(dir, "depot")
            n = PEF.materialize_sealed_depot("sid", ["v1.13/Foo/Foo_x.ji", "v1.13/Foo/missing.ji"], dest)
            @test n == 1   # missing files are skipped, not errors
            target = joinpath(dest, "compiled", "v1.13", "Foo", "Foo_x.ji")
            @test read(target, String) == "content"
            # hardlink, not a copy (same inode) — per-job materialization is free
            @test stat(target).inode == stat(joinpath(src, "Foo_x.ji")).inode
        end
    end
end

@testset "config plumbing" begin
    d = Dict("region" => "r", "queue_url" => "q", "runs_table" => "rt",
             "jobs_table" => "jt", "bucket" => "b", "seal_queue_url" => "sq")
    cfg = FarmConfig(d)
    @test cfg.seal_queue_url == "sq"
    @test PEF.sealing_enabled(cfg)
    @test Dict(cfg)["seal_queue_url"] == "sq"
    @test !PEF.sealing_enabled(FarmConfig(delete!(copy(d), "seal_queue_url")))
    @test PEF.seal_terminal("sealed") && PEF.seal_terminal("unsealable") && PEF.seal_terminal("error")
    @test !PEF.seal_terminal("pending") && !PEF.seal_terminal("running")
    @test PEF.is_seal_job(PEF.JobRef("seal-abc", "seal", "Foo"))
    @test !PEF.is_seal_job(PEF.JobRef("20260729-x", "primary", "Foo"))
    @test PEF.seal_id_of("seal-abc123") == "abc123"
end
@testset "derivation want pins" begin
    # regression: want dep tuples have no `name` field (crashed 45 derivations
    # live); pins must build from uuid+version alone, skipping unkeyables
    want = PEF.parse_want_preimage(join(["v2", "julia=1+a", "name=X",
        "uuid=aaaaaaaa-0000-0000-0000-000000000001", "version=1.0.0",
        "tree=$("11"^20)", "flags=1", "prefs=0",
        "dep=aaaaaaaa-0000-0000-0000-000000000002:1f:4.1.0:$("ab"^32)",
        "dep=aaaaaaaa-0000-0000-0000-000000000003:2f:-:-"], "\n"))
    pins = Dict{String,Any}("aaaaaaaa-0000-0000-0000-000000000004" =>
        Dict("name" => "FromMeta", "uuid" => "aaaaaaaa-0000-0000-0000-000000000004",
             "version" => "2.0.0"))
    PEF.merge_want_pins!(pins, want)
    @test length(pins) == 2                       # unkeyable "-" dep skipped
    @test pins["aaaaaaaa-0000-0000-0000-000000000002"]["version"] == "4.1.0"
    @test !haskey(pins["aaaaaaaa-0000-0000-0000-000000000002"], "name")
    @test pins["aaaaaaaa-0000-0000-0000-000000000004"]["name"] == "FromMeta"
end

end # module

