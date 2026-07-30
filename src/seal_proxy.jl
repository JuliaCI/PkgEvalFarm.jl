# The cache-protocol scheme: a loopback proxy sandboxes fetch compile caches
# through, plus namespaced verified publication.
#
# There is deliberately no global switch. The scheme is decided per seal run
# at expansion — "protocol" iff the julia under test carries
# Base.CACHE_FETCH_HOOK (detected by running it *sandboxed*), "depot"
# otherwise — and recorded on the seal run item, so a run can never straddle
# schemes and hookless julias behave exactly as before the protocol existed.
#
# Trust: the sandbox only ever GETs (the loader revalidates whatever it
# fetched) and POSTs miss reports. Publication happens worker-side, and only
# under the uuid the *registry* — not the sandbox — says the sealed unit has:
# a malicious seal job can therefore only ever poison its own package's
# namespace, which is the package a consumer had already decided to run.

"Scheme recorded on a seal run item; absent (pre-scheme runs) means depot."
seal_run_scheme(run::AbstractDict) = String(get(run, "scheme", "depot"))

# detection runs a sandboxed julia, so memoize per fingerprint per process;
# tests (which have no sandbox) pin the answer via the override
const SCHEME_CACHE = Dict{String,String}()
const SCHEME_LOCK = ReentrantLock()
const SEAL_SCHEME_OVERRIDE = Ref{Union{Nothing,String}}(nothing)

"""
The sealing scheme for a configuration: "protocol" iff its julia carries the
cache-fetch hook. Detection failures (and PkgEval forks without the detector)
fall back to "depot" — the pre-protocol behavior, suboptimal but never a
mixed state.
"""
function detect_seal_scheme(config::PkgEval.Configuration, fingerprint::AbstractString)
    SEAL_SCHEME_OVERRIDE[] === nothing || return something(SEAL_SCHEME_OVERRIDE[])
    lock(SCHEME_LOCK) do
        get!(SCHEME_CACHE, String(fingerprint)) do
            isdefined(PkgEval, :julia_supports_cache_hook) &&
                PkgEval.julia_supports_cache_hook(config) ? "protocol" : "depot"
        end
    end
end

kv_object_key(ns, uuid, key) = "compilecache/$ns/kv/$uuid/$key"

"Wire frame for a cachefile pair: [len_ji::UInt64le][ji][len_so::UInt64le][so].
The pair shares a basename client-side, keeping ocachefile_from_cachefile's
sibling convention intact."
function frame_pair(ji::Vector{UInt8}, so::Union{Nothing,Vector{UInt8}})
    so = something(so, UInt8[])
    vcat(reinterpret(UInt8, [htol(UInt64(length(ji)))]), ji,
         reinterpret(UInt8, [htol(UInt64(length(so)))]), so)
end

"Inverse of `frame_pair`; `nothing` on malformed frames."
function unframe_pair(blob::Vector{UInt8})
    length(blob) >= 16 || return nothing
    len_ji = Int(ltoh(reinterpret(UInt64, blob[1:8])[1]))
    length(blob) >= 16 + len_ji || return nothing
    len_so = Int(ltoh(reinterpret(UInt64, blob[9+len_ji:16+len_ji])[1]))
    length(blob) >= 16 + len_ji + len_so || return nothing
    return blob[9:8+len_ji], blob[17+len_ji:16+len_ji+len_so]
end

"""
Fetch a kv object (`meta=true` for the `.meta` sidecar) through the local
disk cache, then S3; `nothing` when absent. Objects are immutable, so the
disk cache is trusted forever.
"""
function get_kv(ctx::FarmCtx, ns::AbstractString, uuid::AbstractString,
                key::AbstractString; meta::Bool=false)
    suffix = meta ? ".meta" : ""
    local_path = joinpath(seal_cache_root(), ns, "kv", uuid, key * suffix)
    isfile(local_path) && return read(local_path)
    s3key = kv_object_key(ns, uuid, key) * suffix
    body = try
        resp = aws_retry() do
            S3.get_object(ctx.cfg.bucket, s3key, Dict("return_raw" => true);
                          aws_config=ctx.aws)
        end
        copy(resp)
    catch err
        is_not_found(err) || @warn "kv fetch failed" s3key err
        return nothing
    end
    mkpath(dirname(local_path))
    tmp = local_path * ".tmp.$(getpid()).$(objectid(current_task()))"
    write(tmp, body)
    mv(tmp, local_path; force=true)
    return body
end

const SEAL_PROXY = Ref{Any}(nothing)
const PROXY_PATH_RE = r"^/cache/v1/([0-9a-z-]{1,64})/([0-9a-f-]{36})/([0-9a-f]{64})$"
const WANT_PATH_RE = r"^/want/v2/([0-9a-z-]{1,64})$"

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
        negkey = string(ns, '/', uuid, '/', key)
        lock(neg_lock) do
            get(negative, negkey, 0.0) > time()
        end && return nothing
        body = get_kv(ctx, ns, uuid, key)
        body === nothing && lock(() -> negative[negkey] = time() + 30, neg_lock)
        return body
    end

    handler = function (req::HTTP.Request)
        target = req.target
        if req.method == "GET" && (m = match(PROXY_PATH_RE, target)) !== nothing
            body = fetch_kv(String(m[1]), String(m[2]), String(m[3]))
            body === nothing && return HTTP.Response(404)
            return HTTP.Response(200, body)
        elseif req.method == "POST" && (m = match(WANT_PATH_RE, target)) !== nothing
            preimage = String(req.body)
            lock(wants_lock) do
                length(wants) < 10_000 && push!(wants, preimage)
            end
            # a v2 want is a complete derivation request: dedup it into a
            # derivation job so an executor slot can produce the artifact
            try
                ingest_want(ctx, String(m[1]), preimage)
            catch err
                @warn "want ingestion failed" err
            end
            return HTTP.Response(202)
        elseif req.method == "POST" && target == "/want/v1"
            # older clients: telemetry only
            lock(wants_lock) do
                length(wants) < 10_000 && push!(wants, String(req.body))
            end
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

## derivation ingestion (docs/sealing.md, stage 2)
#
# A v2 want preimage carries everything needed to reproduce the requester's
# environment for one package: identity (name/uuid/version/tree), flags/prefs,
# and per direct dep its uuid, build_id, resolved version and own context key.
# Sandbox-authored data throughout — treated as a work order, never as truth
# about namespaces (publication still resolves uuids through the registry).

"Parse a v2 preimage into its fields, or `nothing` when malformed."
function parse_want_preimage(body::AbstractString)
    lines = split(body, '\n')
    (isempty(lines) || lines[1] != "v2") && return nothing
    fields = Dict{String,String}()
    deps = NamedTuple[]
    for line in lines[2:end]
        if startswith(line, "dep=")
            parts = split(chopprefix(line, "dep="), ':')
            length(parts) == 4 || return nothing
            push!(deps, (; uuid=String(parts[1]), build_id=String(parts[2]),
                         version=String(parts[3]), key=String(parts[4])))
        else
            kv = split(line, '='; limit=2)
            length(kv) == 2 || return nothing
            fields[String(kv[1])] = String(kv[2])
        end
    end
    for required in ("name", "uuid", "version", "tree", "julia")
        haskey(fields, required) || return nothing
    end
    occursin(r"^[0-9a-f-]{36}$", fields["uuid"]) || return nothing
    return (; name=fields["name"], uuid=lowercase(fields["uuid"]),
            version=fields["version"], deps)
end

deriv_run_id(ns::AbstractString) = "deriv-" * ns

"Idempotently create the bookkeeping run derivation jobs of one namespace hang off."
function ensure_deriv_run(ctx::FarmCtx, ns::AbstractString)
    run_id = deriv_run_id(ns)
    try
        Dynamodb.put_item(ddb_item(Dict(
                "run_id" => run_id,
                "created_at" => isodate(),
                "submitter" => "derivations",
                "status" => "active",
                "kind" => "deriv",
                "configs" => "[]",
                "packages" => "[]",
                "context" => JSON.json(Dict("seal" => true)),
                "total_jobs" => 0,
                "completed_jobs" => 0)), ctx.cfg.runs_table,
            Dict("ConditionExpression" => "attribute_not_exists(run_id)");
            aws_config=ctx.aws)
    catch err
        is_conditional_failure(err) || rethrow()
    end
    return run_id
end

"""
Turn a v2 want into (at most) one derivation job: conditional item creation
dedups concurrent reporters, and the winning writer enqueues the seal-queue
message. The message's "package" field carries the derivation *key* — the
name would be ambiguous across versions/contexts.
"""
function ingest_want(ctx::FarmCtx, ns::AbstractString, body::AbstractString)
    sealing_enabled(ctx.cfg) || return nothing
    want = parse_want_preimage(body)
    want === nothing && return nothing
    key = bytes2hex(SHA.sha256(codeunits(body)))
    run_id = ensure_deriv_run(ctx, ns)
    try
        Dynamodb.put_item(ddb_item(Dict(
                "run_id" => run_id,
                "job_key" => job_key("deriv", key),
                "config" => "deriv",
                "package" => key,
                "kind" => "deriv",
                "name" => want.name,
                "uuid" => want.uuid,
                "version" => want.version,
                "preimage" => String(body),
                "status" => "pending",
                "attempts" => 0,
                "created_at" => isodate())), ctx.cfg.jobs_table,
            Dict("ConditionExpression" => "attribute_not_exists(run_id)");
            aws_config=ctx.aws)
    catch err
        is_conditional_failure(err) || rethrow()
        return nothing   # already wanted (possibly already produced)
    end
    Dynamodb.update_item(ddb_item(Dict("run_id" => run_id)), ctx.cfg.runs_table,
        Dict("UpdateExpression" => "SET #s = :active REMOVE finished_at ADD total_jobs :one",
             "ExpressionAttributeNames" => Dict("#s" => "status"),
             "ExpressionAttributeValues" => ddb_item(Dict(":active" => "active", ":one" => 1)));
        aws_config=ctx.aws)
    enqueue_jobs(ctx, [JobRef(run_id, "deriv", key)]; queue_url=ctx.cfg.seal_queue_url)
    @info "derivation enqueued" ns want.name want.version key=first(key, 12)
    return key
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
    object_key = kv_object_key(seal_id, lowercase(unit_uuid), key)
    outcome = put_sealed_object(ctx, object_key, body)
    outcome in (:created, :exists_same, :exists_unknown) || return false

    # the .meta sidecar makes the store a by-key DAG: filenames for
    # materialization plus each direct dep's identity and context key, so a
    # closure resolves by fetching keys — no indexes, no build_id lookups.
    # Dep entries are sandbox-reported but carry no authority: a wrong dep key
    # only makes a derivation's closure walk miss and decline.
    rel = splitpath(String(entry["ji"]))
    deps = Any[]
    raw_deps = get(entry, "deps", Any[])
    if raw_deps isa AbstractVector
        for d in raw_deps
            d isa AbstractDict || continue
            push!(deps, Dict("uuid" => lowercase(String(get(d, "uuid", ""))),
                             "name" => String(get(d, "name", "")),
                             "version" => String(get(d, "version", "-")),
                             "key" => String(get(d, "key", "-"))))
        end
    end
    meta = Dict("name" => unit, "uuid" => lowercase(unit_uuid),
                "version" => String(get(entry, "version", "-")),
                "vdir" => rel[1], "ji" => basename(ji_path),
                "so" => so_path === nothing ? "" : basename(so_path),
                "deps" => deps)
    put_sealed_object(ctx, object_key * ".meta",
                      Vector{UInt8}(codeunits(JSON.json(meta)));
                      content_type="application/json")
    return true
end
