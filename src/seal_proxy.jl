# The cache-protocol scheme (PKGEVAL_SEAL_SCHEME=protocol): a loopback proxy
# sandboxes fetch compile caches through, plus namespaced verified publication.
#
# Experimental, behind the flag: it needs a julia-under-test carrying
# Base.CACHE_FETCH_HOOK (the cache-fetch-hook branch) plus the PkgEval fork's
# scripts/cache_client.jl on the other side of the socket. The default
# ("depot") scheme keeps the index/materialized-depot behavior.
#
# Trust: the sandbox only ever GETs (the loader revalidates whatever it
# fetched) and POSTs miss reports. Publication happens worker-side, and only
# under the uuid the *registry* — not the sandbox — says the sealed unit has:
# a malicious seal job can therefore only ever poison its own package's
# namespace, which is the package a consumer had already decided to run.

seal_scheme() = get(ENV, "PKGEVAL_SEAL_SCHEME", "depot")
protocol_scheme() = seal_scheme() == "protocol"

kv_object_key(ns, uuid, key) = "compilecache/$ns/kv/$uuid/$key"

"Wire frame for a cachefile pair: [len_ji::UInt64le][ji][len_so::UInt64le][so].
The pair shares a basename client-side, keeping ocachefile_from_cachefile's
sibling convention intact."
function frame_pair(ji::Vector{UInt8}, so::Union{Nothing,Vector{UInt8}})
    so = something(so, UInt8[])
    vcat(reinterpret(UInt8, [htol(UInt64(length(ji)))]), ji,
         reinterpret(UInt8, [htol(UInt64(length(so)))]), so)
end

const SEAL_PROXY = Ref{Any}(nothing)
const PROXY_PATH_RE = r"^/cache/v1/([0-9a-f]{1,64})/([0-9a-f-]{36})/([0-9a-f]{64})$"

"""
Start the loopback proxy. GETs are served from the local kv cache, then S3
(cached locally, immutable); misses 404 with a short negative cache. `/want`
reports are collected for observability (and, later, derivation scheduling).
"""
function start_seal_proxy!(ctx::FarmCtx)
    negative = Dict{String,Float64}()
    neg_lock = ReentrantLock()
    wants = String[]
    wants_lock = ReentrantLock()

    function fetch_kv(ns, uuid, key)
        local_path = joinpath(seal_cache_root(), ns, "kv", uuid, key)
        isfile(local_path) && return read(local_path)
        s3key = kv_object_key(ns, uuid, key)
        lock(neg_lock) do
            get(negative, s3key, 0.0) > time()
        end && return nothing
        body = try
            resp = aws_retry() do
                S3.get_object(ctx.cfg.bucket, s3key, Dict("return_raw" => true);
                              aws_config=ctx.aws)
            end
            copy(resp)
        catch err
            is_not_found(err) || @warn "kv fetch failed" s3key err
            lock(() -> negative[s3key] = time() + 30, neg_lock)
            return nothing
        end
        mkpath(dirname(local_path))
        tmp = local_path * ".tmp.$(getpid()).$(objectid(current_task()))"
        write(tmp, body)
        mv(tmp, local_path; force=true)
        return body
    end

    handler = function (req::HTTP.Request)
        target = req.target
        if req.method == "GET" && (m = match(PROXY_PATH_RE, target)) !== nothing
            body = fetch_kv(String(m[1]), String(m[2]), String(m[3]))
            body === nothing && return HTTP.Response(404)
            return HTTP.Response(200, body)
        elseif req.method == "POST" && target == "/want/v1"
            preimage = String(req.body)
            lock(wants_lock) do
                length(wants) < 10_000 && push!(wants, preimage)
            end
            @debug "cache want" preimage=first(preimage, 200)
            return HTTP.Response(202)
        end
        return HTTP.Response(404)
    end

    # explicit random port with retry: HTTP.port() does not report the bound
    # port for an ephemeral listen
    server, port = nothing, 0
    for attempt in 1:10
        port = rand(30001:40000)
        try
            server = HTTP.serve!(handler, "127.0.0.1", port)
            break
        catch err
            attempt == 10 && rethrow()
        end
    end
    SEAL_PROXY[] = (; server, port, wants, wants_lock)
    @info "seal cache proxy started" port
    return SEAL_PROXY[]
end

function stop_seal_proxy!()
    proxy = SEAL_PROXY[]
    proxy === nothing && return nothing
    SEAL_PROXY[] = nothing
    close(proxy.server)
    return nothing
end

"Registered name -> uuid from a registry checkout — the *trusted* namespace
authority for publication (never the sandbox's claim)."
function registry_uuid(registry_dir::AbstractString, name::AbstractString)
    registry = TOML.parsefile(joinpath(registry_dir, "Registry.toml"))
    for (uuid, entry) in get(registry, "packages", Dict())
        entry["name"] == name && return lowercase(String(uuid))
    end
    return nothing
end

"""
    publish_protocol!(ctx, seal_id, export_dir, unit, unit_uuid) -> Bool

Publish a seal job's produced cachefile pair under the *registry-resolved*
uuid namespace, at the key the in-sandbox client computed. The sandbox's own
uuid claim is only sanity-checked: on mismatch nothing is published (a lying
key preimage merely produces an object no honest consumer ever asks for; a
lying namespace would be poisoning, and the sandbox doesn't get to pick it).
"""
function publish_protocol!(ctx::FarmCtx, seal_id::AbstractString, export_dir::AbstractString,
                           unit::AbstractString, unit_uuid::AbstractString)
    keys_file = joinpath(export_dir, "seal_keys.toml")
    isfile(keys_file) || return false
    data = try
        TOML.parsefile(keys_file)
    catch err
        @warn "unparsable seal_keys.toml" unit err
        return false
    end
    entry = get(data, unit, nothing)
    entry isa AbstractDict || return false
    if lowercase(String(get(entry, "uuid", ""))) != lowercase(unit_uuid)
        @warn "seal job claimed a foreign uuid; refusing to publish" unit claimed=get(entry, "uuid", "")
        return false
    end
    key = String(get(entry, "key", ""))
    occursin(r"^[0-9a-f]{64}$", key) || return false
    compiled = joinpath(export_dir, "compiled")
    # the produced files must live under the unit's own cache dir — a rel path
    # is sandbox-controlled data
    function unit_file(rel)
        isempty(rel) && return nothing
        path = normpath(joinpath(compiled, rel))
        startswith(path, compiled * "/") || return nothing
        parts = splitpath(relpath(path, compiled))
        (length(parts) == 3 && parts[2] == unit && isfile(path)) || return nothing
        return path
    end
    ji_path = unit_file(String(get(entry, "ji", "")))
    ji_path === nothing && return false
    so_path = unit_file(String(get(entry, "so", "")))
    body = frame_pair(read(ji_path), so_path === nothing ? nothing : read(so_path))
    outcome = put_sealed_object(ctx, kv_object_key(seal_id, lowercase(unit_uuid), key), body)
    return outcome in (:created, :exists_same, :exists_unknown)
end
