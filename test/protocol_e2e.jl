# End-to-end test of the cache-protocol client (PkgEval's scripts/cache_client.jl)
# against a julia build carrying Base.CACHE_FETCH_HOOK.
#
# Skipped unless PKGEVAL_HOOK_JULIA points at such a build (CI julias don't
# carry the hook yet); run locally against a cache-fetch-hook branch build.
# Two fabricated registry-style packages (ProtoPkg -> DepPkg) exercise the v2
# preimage's dep lines (version + the dep's own context key): a producer
# compiles both and emits their keys; the host frames the cachefile pairs and
# serves them from a stub proxy; a consumer with a cold depot must then load
# ProtoPkg through the hook with zero local compiles (DepPkg fetched first, so
# ProtoPkg's dep build_id — and therefore its key — matches the producer's);
# misses must surface as /want/v2 reports carrying the full context.

module ProtocolE2E

using Test
using JSON
using TOML
import HTTP

hook_julia = get(ENV, "PKGEVAL_HOOK_JULIA", "")
client_jl = normpath(joinpath(@__DIR__, "..", "..", "PkgEval.jl", "scripts", "cache_client.jl"))

if isempty(hook_julia) || !isfile(client_jl)
    @test_skip "protocol e2e (set PKGEVAL_HOOK_JULIA to a hook-carrying build)"
else

const UUID_S = "c0ffee00-1234-4321-abcd-0123456789ab"
const TREE = "1111111111111111111111111111111111111111"
const DEP_UUID = "c0ffee00-1234-4321-abcd-0123456789ac"
const DEP_TREE = "2222222222222222222222222222222222222222"

function setup_depot(dir)
    # compute the package-store slugs with the julia under test, so layout
    # matches what its loader expects for registry-installed packages
    slug(u, t) = readchomp(`$hook_julia --startup-file=no -e "print(Base.version_slug(Base.UUID(\"$u\"), Base.SHA1(\"$t\")))"`)
    depot = joinpath(dir, "depot")
    src = joinpath(depot, "packages", "ProtoPkg", slug(UUID_S, TREE), "src")
    mkpath(src)
    write(joinpath(src, "ProtoPkg.jl"),
          "module ProtoPkg\nusing DepPkg\nanswer() = DepPkg.base() + 1\nend\n")
    dep_src = joinpath(depot, "packages", "DepPkg", slug(DEP_UUID, DEP_TREE), "src")
    mkpath(dep_src)
    write(joinpath(dep_src, "DepPkg.jl"), "module DepPkg\nbase() = 41\nend\n")
    proj = joinpath(dir, "proj")
    mkpath(proj)
    write(joinpath(proj, "Project.toml"), """
        [deps]
        ProtoPkg = "$UUID_S"
        """)
    write(joinpath(proj, "Manifest.toml"), """
        julia_version = "1.14.0"
        manifest_format = "2.0"

        [[deps.ProtoPkg]]
        deps = ["DepPkg"]
        git-tree-sha1 = "$TREE"
        uuid = "$UUID_S"
        version = "0.1.0"

        [[deps.DepPkg]]
        git-tree-sha1 = "$DEP_TREE"
        uuid = "$DEP_UUID"
        version = "0.2.0"
        """)
    return depot, proj
end

function run_client(depot, proj, server, script; namespace="e2e")
    cmd = `$hook_julia --startup-file=no --project=$proj -e $("""
        include($(repr(client_jl)))
        $script
        """)`
    env = ["JULIA_DEPOT_PATH" => depot * ":",
           "PKGEVAL_CACHE_SERVER" => server,
           "PKGEVAL_CACHE_NAMESPACE" => namespace]
    out = IOBuffer()
    ok = success(pipeline(addenv(cmd, env...); stdout=out, stderr=out))
    return ok, String(take!(out))
end

parse_keys(file, unit) = TOML.parsefile(file)[unit]

@testset "protocol end-to-end" begin
    mktempdir() do dir
        depot_a, proj = setup_depot(dir)

        # producer: compile cold, then emit context keys for both units
        keys_unit = joinpath(dir, "keys_unit.toml")
        keys_dep = joinpath(dir, "keys_dep.toml")
        ok, out = run_client(depot_a, proj, "http://127.0.0.1:1", """
            using ProtoPkg
            @assert ProtoPkg.answer() == 42
            PkgEvalCacheClient.emit_produced_keys("ProtoPkg", $(repr(keys_unit)))
            PkgEvalCacheClient.emit_produced_keys("DepPkg", $(repr(keys_dep)))
            """)
        @test ok || error(out)
        unit = parse_keys(keys_unit, "ProtoPkg")
        dep = parse_keys(keys_dep, "DepPkg")
        @test unit["uuid"] == UUID_S && dep["uuid"] == DEP_UUID
        @test occursin(r"^[0-9a-f]{64}$", unit["key"])
        @test occursin(r"^[0-9a-f]{64}$", dep["key"])
        # the v2 preimage pins the dep's version and its own context key
        preimage = unit["preimage"]
        @test startswith(preimage, "v2\n")
        @test occursin("name=ProtoPkg", preimage)
        @test occursin("dep=$DEP_UUID:", preimage)
        @test occursin(":0.2.0:$(dep["key"])", preimage)
        # ...and the emitted deps table matches (the .meta sidecar's source)
        unit_deps = unit["deps"]
        @test any(d -> d["uuid"] == DEP_UUID && d["key"] == dep["key"] &&
                       d["version"] == "0.2.0", unit_deps)

        # frame both produced pairs the way the worker's publisher does
        compiled_a = joinpath(depot_a, "compiled")
        function frame_of(entry)
            ji = read(joinpath(compiled_a, entry["ji"]))
            so = isempty(entry["so"]) ? UInt8[] : read(joinpath(compiled_a, entry["so"]))
            vcat(reinterpret(UInt8, [htol(UInt64(length(ji)))]), ji,
                 reinterpret(UInt8, [htol(UInt64(length(so)))]), so)
        end
        frames = Dict("/cache/v1/e2e/$(UUID_S)/$(unit["key"])" => frame_of(unit),
                      "/cache/v1/e2e/$(DEP_UUID)/$(dep["key"])" => frame_of(dep))

        # stub proxy: serve exactly the producer's keys, collect wants
        wants = String[]
        handler = req -> begin
            if req.method == "GET" && haskey(frames, req.target)
                return HTTP.Response(200, frames[req.target])
            elseif req.method == "POST" && startswith(req.target, "/want/v2/")
                push!(wants, String(req.body))
                return HTTP.Response(202)
            end
            return HTTP.Response(404)
        end
        port, server = 0, nothing
        for attempt in 1:10
            port = rand(30001:40000)
            try
                server = HTTP.serve!(handler, "127.0.0.1", port)
                break
            catch err
                attempt == 10 && rethrow()
            end
        end
        base = "http://127.0.0.1:$port"
        try
            # consumer: cold depot, same sources -> loads through the hook
            # alone: DepPkg fetched first, so ProtoPkg's key matches
            depot_b = joinpath(dir, "depot_b")
            mkpath(depot_b)
            cp(joinpath(depot_a, "packages"), joinpath(depot_b, "packages"))
            ok, out = run_client(depot_b, proj, base, """
                PkgEvalCacheClient.install!()
                using ProtoPkg
                @assert ProtoPkg.answer() == 42
                @assert PkgEvalCacheClient.HITS[] == 2   # DepPkg, then ProtoPkg
                for (name, uuid) in (("ProtoPkg", "$UUID_S"), ("DepPkg", "$DEP_UUID"))
                    id = Base.PkgId(Base.UUID(uuid), name)
                    cachefile = only(Base.find_all_in_cache_path(id))
                    @assert occursin("_fetched", basename(cachefile))
                end
                println("CONSUMER_OK")
                """)
            @test ok || error(out)
            @test occursin("CONSUMER_OK", out)

            # a consumer the server has nothing for (different namespace)
            # compiles locally and reports misses with full context
            depot_c = joinpath(dir, "depot_c")
            mkpath(depot_c)
            cp(joinpath(depot_a, "packages"), joinpath(depot_c, "packages"))
            empty!(wants)
            ok, out = run_client(depot_c, proj, base, """
                PkgEvalCacheClient.install!()
                using ProtoPkg
                @assert ProtoPkg.answer() == 42
                @assert PkgEvalCacheClient.HITS[] == 0
                println("MISS_OK")
                """; namespace="other")
            @test ok || error(out)
            @test occursin("MISS_OK", out)
            @test !isempty(wants)
            @test any(w -> occursin("uuid=$UUID_S", w) && occursin("tree=$TREE", w), wants)
            @test all(w -> startswith(w, "v2\n"), wants)
        finally
            close(server)
        end
    end
end

end # hook available

end # module
