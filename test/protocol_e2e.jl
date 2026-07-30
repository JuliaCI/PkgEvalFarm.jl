# End-to-end test of the cache-protocol client (PkgEval's scripts/cache_client.jl)
# against a julia build carrying Base.CACHE_FETCH_HOOK.
#
# Skipped unless PKGEVAL_HOOK_JULIA points at such a build (CI julias don't
# carry the hook yet); run locally against a cache-fetch-hook branch build.
# The producer process compiles a fabricated registry-style package and emits
# its context key; the host frames the cachefile pair and serves it from a
# stub proxy; a consumer process with a cold depot must then load the package
# through the hook without compiling, and misses must surface as /want
# reports carrying the full context.

module ProtocolE2E

using Test
using JSON
import HTTP

hook_julia = get(ENV, "PKGEVAL_HOOK_JULIA", "")
client_jl = normpath(joinpath(@__DIR__, "..", "..", "PkgEval.jl", "scripts", "cache_client.jl"))

if isempty(hook_julia) || !isfile(client_jl)
    @test_skip "protocol e2e (set PKGEVAL_HOOK_JULIA to a hook-carrying build)"
else

const UUID_S = "c0ffee00-1234-4321-abcd-0123456789ab"
const TREE = "1111111111111111111111111111111111111111"

function setup_depot(dir)
    # compute the package-store slug with the julia under test, so layout
    # matches what its loader expects for a registry-installed package
    slug = readchomp(`$hook_julia --startup-file=no -e "print(Base.version_slug(Base.UUID(\"$UUID_S\"), Base.SHA1(\"$TREE\")))"`)
    depot = joinpath(dir, "depot")
    src = joinpath(depot, "packages", "ProtoPkg", slug, "src")
    mkpath(src)
    write(joinpath(src, "ProtoPkg.jl"), "module ProtoPkg\nanswer() = 42\nend\n")
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
        git-tree-sha1 = "$TREE"
        uuid = "$UUID_S"
        version = "0.1.0"
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

@testset "protocol end-to-end" begin
    mktempdir() do dir
        depot_a, proj = setup_depot(dir)

        # producer: compile cold, then emit the context key for the unit
        keysfile = joinpath(dir, "keys.toml")
        ok, out = run_client(depot_a, proj, "http://127.0.0.1:1", """
            using ProtoPkg
            @assert ProtoPkg.answer() == 42
            PkgEvalCacheClient.emit_produced_keys("ProtoPkg", $(repr(keysfile)))
            """)
        @test ok || error(out)
        @test isfile(keysfile)
        entry = Dict{String,Any}()
        for line in eachline(keysfile)
            m = match(r"^(\w+) = \"(.*)\"$", line)
            m !== nothing && (entry[m[1]] = m[2])
        end
        @test entry["uuid"] == UUID_S
        @test occursin(r"^[0-9a-f]{64}$", entry["key"])
        @test occursin("tree=$TREE", replace(entry["preimage"], "\\n" => "\n"))

        # frame the produced pair the way the worker's publisher does
        compiled_a = joinpath(depot_a, "compiled")
        ji = read(joinpath(compiled_a, entry["ji"]))
        so_rel = entry["so"]
        so = isempty(so_rel) ? UInt8[] : read(joinpath(compiled_a, so_rel))
        frame = vcat(reinterpret(UInt8, [htol(UInt64(length(ji)))]), ji,
                     reinterpret(UInt8, [htol(UInt64(length(so)))]), so)

        # stub proxy: serve exactly the producer's key, collect wants
        wants = String[]
        handler = req -> begin
            if req.method == "GET" && req.target == "/cache/v1/e2e/$(UUID_S)/$(entry["key"])"
                return HTTP.Response(200, frame)
            elseif req.method == "POST" && req.target == "/want/v1"
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
            # consumer: cold depot, same sources -> must load via the hook,
            # not by compiling
            depot_b = joinpath(dir, "depot_b")
            mkpath(depot_b)
            cp(joinpath(depot_a, "packages"), joinpath(depot_b, "packages"))
            ok, out = run_client(depot_b, proj, base, """
                PkgEvalCacheClient.install!()
                using ProtoPkg
                @assert ProtoPkg.answer() == 42
                @assert PkgEvalCacheClient.HITS[] == 1
                cachefile = only(Base.find_all_in_cache_path(Base.identify_package("ProtoPkg")))
                @assert occursin("_fetched", basename(cachefile))
                println("CONSUMER_OK")
                """)
            @test ok || error(out)
            @test occursin("CONSUMER_OK", out)

            # a consumer the server has nothing for (different namespace)
            # compiles locally and reports the miss with its full context
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
            @test occursin("uuid=$UUID_S", wants[end])
            @test occursin("tree=$TREE", wants[end])
        finally
            close(server)
        end
    end
end

end # hook available

end # module
