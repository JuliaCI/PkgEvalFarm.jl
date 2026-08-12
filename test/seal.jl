# Unit tests for the sealing machinery that need no AWS (see moto.jl for the
# integration side).

module SealTests

using Test
using PkgEvalFarm
using TOML
using UUIDs: UUID, uuid5
import PkgEval

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

        # uuid membership (the extension-parent trust check)
        @test PEF.registry_has_uuid(reg, "aaaaaaaa-0000-0000-0000-000000000001")
        @test PEF.registry_has_uuid(reg, "AAAAAAAA-0000-0000-0000-000000000001")
        @test !PEF.registry_has_uuid(reg, "aaaaaaaa-0000-0000-0000-00000000dead")

        # learned edges merge in (and are clipped to the run set)
        merged = PEF.seal_dep_graph(reg, sort(collect(wanted)),
                                    Dict("Crayons" => ["Example", "NotInRun"]))
        @test merged["Crayons"] == ["Example"]
        @test merged["JSON"] == ["Crayons", "Example"]

        # cycles deadlock the readiness counters; untangling drops the LEARNED
        # back-edge and keeps the registry direction, so the dependent still
        # seals warm (the Compat <-> SHA class: cycles usually close via a
        # test-dep edge)
        cyc = PEF.seal_dep_graph(reg, sort(collect(wanted)),
                                 Dict("Crayons" => ["JSON"]))
        @test cyc["JSON"] == ["Crayons", "Example"]   # registry edge survives
        @test cyc["Crayons"] == String[]              # the learned closure is the cut
        @test cyc["Example"] == String[]

        # residual registry-level cycles (version-range unions) serialize as a
        # lexicographic chain: the later member keeps its dep on the earlier,
        # so it seals consuming its predecessor's artifact
        mktempdir() do reg2
            mkpath(joinpath(reg2, "A", "Alpha"))
            mkpath(joinpath(reg2, "B", "Beta"))
            write(joinpath(reg2, "Registry.toml"), """
                [packages]
                bbbbbbbb-0000-0000-0000-000000000001 = { name = "Alpha", path = "A/Alpha" }
                bbbbbbbb-0000-0000-0000-000000000002 = { name = "Beta", path = "B/Beta" }
                """)
            write(joinpath(reg2, "A", "Alpha", "Deps.toml"), """
                ["0"]
                Beta = "bbbbbbbb-0000-0000-0000-000000000002"
                """)
            write(joinpath(reg2, "B", "Beta", "Deps.toml"), """
                ["0"]
                Alpha = "bbbbbbbb-0000-0000-0000-000000000001"
                """)
            chain = PEF.seal_dep_graph(reg2, ["Alpha", "Beta"])
            @test chain["Alpha"] == String[]
            @test chain["Beta"] == ["Alpha"]
        end
    end

    @testset "strongly connected components" begin
        comp = PEF.scc_ids(Dict("A" => ["B"], "B" => ["C"], "C" => ["A", "D"],
                                "D" => String[], "E" => ["D", "X"]))
        @test comp["A"] == comp["B"] == comp["C"]
        @test comp["D"] != comp["A"] && comp["E"] != comp["D"] && comp["E"] != comp["A"]
        @test !haskey(comp, "X")   # dep-only nodes are external to the map
        # an acyclic diamond stays four singleton components
        @test length(unique(values(PEF.scc_ids(Dict("A" => ["B", "C"], "B" => ["D"],
                                                    "C" => ["D"], "D" => String[]))))) == 4
        # two disjoint 2-cycles do not merge
        comp2 = PEF.scc_ids(Dict("A" => ["B"], "B" => ["A"], "C" => ["D"], "D" => ["C"]))
        @test comp2["A"] == comp2["B"] && comp2["C"] == comp2["D"] && comp2["A"] != comp2["C"]
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
@testset "v3 extension preimages" begin
    parent = "aaaaaaaa-0000-0000-0000-000000000001"
    ext_uuid = string(uuid5(UUID(parent), "FooBarExt"))
    lines(u) = join(["v3", "julia=1+a", "name=FooBarExt", "uuid=$u",
                     "ext_of=$parent", "version=1.0.0", "tree=$("11"^20)",
                     "flags=1", "prefs=0",
                     "dep=$parent:1f:1.0.0:$("ab"^32)",
                     "dep=aaaaaaaa-0000-0000-0000-000000000002:2f:-:-"], "\n")
    want = PEF.parse_want_preimage(lines(ext_uuid))
    @test want !== nothing
    @test want.ext_of == parent
    @test want.name == "FooBarExt"
    # the uuid must carry uuid5's forced version/variant bits (the exact value
    # is only computable by the deriving julia — its internal hash varies)
    @test PEF.parse_want_preimage(lines("aaaaaaaa-0000-0000-0000-00000000dead")) === nothing
    @test PEF.is_uuid5_shaped(ext_uuid)
    @test !PEF.is_uuid5_shaped("aaaaaaaa-0000-0000-0000-000000000001")  # v0 bits
    @test !PEF.is_uuid5_shaped("not-a-uuid")
    # v2 packages parse as before, with no ext_of
    v2 = PEF.parse_want_preimage(join(["v2", "julia=1+a", "name=Foo",
        "uuid=$parent", "version=1.0.0", "tree=$("11"^20)",
        "flags=1", "prefs=0"], "\n"))
    @test v2 !== nothing && v2.ext_of === nothing

    # extension pins carry unversioned (stdlib) triggers as uuid-only directs
    pins = Dict{String,Any}()
    PEF.merge_want_pins!(pins, want; include_unversioned=true)
    @test pins[parent]["version"] == "1.0.0"
    @test pins["aaaaaaaa-0000-0000-0000-000000000002"] ==
          Dict("uuid" => "aaaaaaaa-0000-0000-0000-000000000002")
    # ...but never for package derivations (the default)
    pins2 = Dict{String,Any}()
    PEF.merge_want_pins!(pins2, want)
    @test !haskey(pins2, "aaaaaaaa-0000-0000-0000-000000000002")
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

@testset "publisher pkgimages" begin
    cfg = PkgEval.Configuration(; julia_args=["--threads=2"])
    pub = PEF.publisher_config(cfg; goal=:seal)
    @test pub.julia_args == ["--threads=2", "--pkgimages=yes"]
    @test pub.goal === :seal
    # an explicit pkgimages choice in the run's julia_args wins
    cfg2 = PkgEval.Configuration(; julia_args=["--pkgimages=no"])
    @test PEF.publisher_config(cfg2).julia_args == ["--pkgimages=no"]
    # fleet-portable codegen target, overridable; empty opts out entirely
    withenv("PKGEVAL_SEAL_CPU_TARGET" => nothing) do
        @test PEF.seal_cpu_target() == "haswell,-rdrnd"
    end
    withenv("PKGEVAL_SEAL_CPU_TARGET" => "znver3") do
        @test PEF.seal_cpu_target() == "znver3"
    end
end

end # module

