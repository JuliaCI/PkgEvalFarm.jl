# The cache protocol: a loopback proxy sandboxes fetch compile caches
# through, plus namespaced verified publication.
#
# Sealing requires the julia under test to carry Base.CACHE_FETCH_HOOK
# (detected by running it *sandboxed* at expansion); hookless julias simply
# run unsealed, exactly as before sealing existed. The scheme is recorded on
# the seal run item so gates can recognize runs from retired schemes (the
# pre-hook "depot" scheme) and run cold against them instead of misreading
# them.
#
# Trust: the sandbox only ever GETs (the loader revalidates whatever it
# fetched) and POSTs miss reports. Publication happens worker-side, and only
# under the uuid the *registry* — not the sandbox — says the sealed unit has:
# a malicious seal job can therefore only ever poison its own package's
# namespace, which is the package a consumer had already decided to run.

"Scheme recorded on a seal run item; anything but \"protocol\" (retired
schemes, pre-scheme runs) gates nothing — consumers run cold."
seal_run_scheme(run::AbstractDict) = String(get(run, "scheme", ""))

# detection runs a sandboxed julia, so memoize per fingerprint per process;
# tests (which have no sandbox) pin the answer via the override
const SEAL_SUPPORT_CACHE = Dict{String,Bool}()
const SCHEME_LOCK = ReentrantLock()
const SEAL_SUPPORT_OVERRIDE = Ref{Union{Nothing,Bool}}(nothing)

"""
Whether a configuration's julia carries the cache-fetch hook. Only definitive
probe verdicts are returned (and memoized): a probe that could not run throws
through to the caller — expansion retries it later — instead of freezing
"unsupported" into a run (#12). PkgEval forks without the detector are
definitively hookless.
"""
function detect_seal_support(config::PkgEval.Configuration, fingerprint::AbstractString)
    SEAL_SUPPORT_OVERRIDE[] === nothing || return something(SEAL_SUPPORT_OVERRIDE[])
    lock(SCHEME_LOCK) do
        get!(SEAL_SUPPORT_CACHE, String(fingerprint)) do
            isdefined(PkgEval, :julia_supports_cache_hook) &&
                PkgEval.julia_supports_cache_hook(config)
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
        aws_retry() do
            try
                copy(S3.get_object(ctx.cfg.bucket, s3key, Dict("return_raw" => true);
                                   aws_config=ctx.aws))
            catch err
                # absence is an answer, not a retryable failure — retrying a
                # NoSuchKey burns ~8-30s of backoff per miss
                is_not_found(err) ? nothing : rethrow()
            end
        end
    catch err
        @warn "kv fetch failed" s3key err
        nothing
    end
    body === nothing && return nothing
    try
        mkpath(dirname(local_path))
        tmp = local_path * ".tmp.$(getpid()).$(objectid(current_task()))"
        write(tmp, body)
        mv(tmp, local_path; force=true)
    catch err
        # the disk cache is an optimization; serving the fetched bytes is the
        # job (seen live: an uncreatable cache dir turned every hit into a 500)
        @warn "kv disk cache write failed; serving from memory" local_path err maxlog=1
    end
    return body
end

const SEAL_PROXY = Ref{Any}(nothing)

# Holds: a GET whose exact key has a derivation in flight blocks until the
# artifact lands (dataflow ordering by blocking — the sandbox idles at zero
# CPU). While holds are active the worker donates slots to seal-queue work
# (typically the very derivations being waited on): run_worker registers the
# donor closure. Holds are only taken for derivable wants (every keyable dep
# published, see `want_derivable`), and test jobs additionally bound the
# client-side fetch deadline, so a stuck derivation degrades to a local
# compile instead of eating the evaluation's time budget (#11).
const SEAL_DONOR = Ref{Any}(nothing)
const ACTIVE_HOLDS = Threads.Atomic{Int}(0)

maybe_donate!() = ((donor = SEAL_DONOR[]) === nothing || donor(); nothing)

"How long a hold may block before degrading to a local compile: it must
resolve comfortably inside PkgEval's inactivity window (~40 min), or the very
job the hold serves gets killed for idling — the one outcome worse than a
private compile."
hold_limit() = something(tryparse(Float64, get(ENV, "PKGEVAL_CACHE_HOLD_LIMIT", "")), 20.0 * 60)

"""
Block a missed GET while `key`'s derivation is pending/running, until the
artifact publishes or the derivation goes terminal (404: canonical will never
exist, so a local compile is then *correct*, not a compromise).

Releasing early makes the requester compile a private copy of something the
rest of its job expects to share — waste, but bounded waste. Blocking past
the requester's inactivity window gets the requester *killed* — unbounded
damage. So holds are capped inside that window, and the holder heals what it
waits on: it is the one party guaranteed to still exist while a derivation
is wedged (the ingester may be long dead), so it re-arms the derivation's
message whenever the item shows no sign of life (rearm_derivation!).
A derivation that dies terminally releases every holder through the status
check.

Underivable wants never reach here (see `want_derivable`): a hold is only
ever taken for a key some derivation can actually produce.
"""
function hold_for_derivation(ctx::FarmCtx, ns::AbstractString, uuid::AbstractString,
                             key::AbstractString)
    job = JobRef(deriv_run_id(ns), "deriv", key)
    item = get_seal_item(ctx, job)
    item === nothing && return nothing
    status = String(get(item, "status", ""))
    # already terminal on arrival: one authoritative store look, exactly like
    # the in-loop terminal branch. The caller's fetch_kv may have answered
    # from the 30s negative cache, poisoned by a *previous* requester's miss
    # whose derivation has since published — returning nothing here 404'd a
    # published artifact (seen in sim: a sealed TestEnv counted as a miss)
    status in ("pending", "running") || return get_kv(ctx, ns, uuid, key)
    Threads.atomic_add!(ACTIVE_HOLDS, 1)
    try
        deadline = time() + hold_limit()
        while time() < deadline
            # a held slot's capacity is donated for the ENTIRE hold, not once:
            # each donor runs a single seal-queue job and retires, so this must
            # re-offer every iteration (the donor cap makes it idempotent —
            # measured live: one-shot donation left slots idle for the
            # remaining ~18 minutes of a capped hold, fleet at 30% CPU)
            maybe_donate!()
            sleep(3)
            body = get_kv(ctx, ns, uuid, key)
            body === nothing || return body
            item = get_seal_item(ctx, job)
            terminal = item === nothing ||
                       seal_terminal(String(get(item, "status", "sealed")))
            # one last store look after a terminal flip (publish precedes the
            # status write, but be safe about interleavings)
            terminal && return get_kv(ctx, ns, uuid, key)
            try
                rearm_derivation!(ctx, job.run_id, key, item)
            catch err
                @warn "holder re-arm failed" key=first(key, 12) err
            end
        end
        return nothing
    finally
        Threads.atomic_sub!(ACTIVE_HOLDS, 1)
    end
end
const PROXY_PATH_RE = r"^/cache/v1/([0-9a-z-]{1,64})/([0-9a-f-]{36})/([0-9a-f]{64})$"
const WANT_PATH_RE = r"^/want/v2/([0-9a-z-]{1,64})$"
const ENSURE_PATH_RE = r"^/ensure/v2/([0-9a-z-]{1,64})$"

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
            ns, uuid, key = String(m[1]), String(m[2]), String(m[3])
            body = fetch_kv(ns, uuid, key)
            body === nothing && (body = hold_for_derivation(ctx, ns, uuid, key))
            body === nothing && return HTTP.Response(404)
            return HTTP.Response(200, body)
        elseif req.method == "POST" && (m = match(ENSURE_PATH_RE, target)) !== nothing
            # the request IS the preimage: serve the artifact, or create its
            # derivation and hold this very request until it terminates —
            # every requester (including the context's first) waits for the
            # canonical artifact; 404 = terminally underivable, compile
            # locally with a clear conscience
            preimage = String(req.body)
            want = parse_want_preimage(preimage)
            want === nothing && return HTTP.Response(400)
            ns = String(m[1])
            key = bytes2hex(SHA.sha256(codeunits(preimage)))
            lock(wants_lock) do
                length(wants) < 10_000 && push!(wants, preimage)
            end
            body = fetch_kv(ns, want.uuid, key)
            if body === nothing
                if HTTP.header(req, "X-Nohold", "") == "1"
                    # probe from a derivation: answer from the store without
                    # holding or enqueuing (the consumer's own wants already
                    # schedule the chain); authoritative look because the
                    # negative cache may postdate a sibling's publish
                    body = get_kv(ctx, ns, want.uuid, key)
                elseif !want_derivable(ctx, ns, want)
                    # a keyable dep without a published artifact was a local
                    # compile in the requester's sandbox: the wanted key embeds
                    # a build_id no derivation can reproduce, so holding would
                    # wait out a full derivation for a guaranteed 404, and
                    # enqueuing would spend an executor slot on an artifact no
                    # future consumer can address. The dep misses themselves
                    # already scheduled the derivations that eventually make
                    # contexts like this one derivable.
                    @info "underivable want; answering without hold" ns name=want.name key=first(key, 12)
                    body = get_kv(ctx, ns, want.uuid, key)
                else
                    try
                        ingest_want(ctx, ns, preimage)
                    catch err
                        @warn "ensure ingestion failed" err
                    end
                    body = hold_for_derivation(ctx, ns, want.uuid, key)
                end
            end
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
            # a handler exception must degrade to a plain 500, not tear the
            # connection down mid-request (clients treat both as misses, but
            # 500s keep the failure visible and the connection reusable)
            server = HTTP.serve!("127.0.0.1", port) do req
                try
                    handler(req)
                catch err
                    @warn "proxy request failed" target=req.target err
                    HTTP.Response(500)
                end
            end
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

"""
Parse a v2/v3 preimage into its fields, or `nothing` when malformed.

v3 extends v2 with an `ext_of=<parent uuid>` line: the unit is a package
extension whose uuid must equal uuid5(ext_of, name) — verified here, so
downstream code can trust the *derivation* (though never the claim itself:
publication authority still comes from computing the uuid ourselves).
"""
function parse_want_preimage(body::AbstractString)
    lines = split(body, '\n')
    isempty(lines) && return nothing
    v3 = lines[1] == "v3"
    (v3 || lines[1] == "v2") || return nothing
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
    ext_of = nothing
    if v3
        ext_of = lowercase(get(fields, "ext_of", ""))
        occursin(r"^[0-9a-f-]{36}$", ext_of) || return nothing
        # The loader derives extension uuids with Base's internal uuid5, whose
        # underlying `hash` differs across julia versions — the host cannot
        # recompute the value the julia under test produced. What we CAN
        # check: the claimed uuid carries uuid5's forced version/variant bits.
        # Authority doesn't rest on this anyway — the sha256 key binds the
        # full preimage (uuid, name, ext_of, deps), so an object is only ever
        # fetched by a client that honestly computed this exact preimage.
        is_uuid5_shaped(fields["uuid"]) || return nothing
    end
    return (; name=fields["name"], uuid=lowercase(fields["uuid"]),
            version=fields["version"], ext_of, deps)
end

"""
Whether a derivation could ever produce `want`'s key: every keyable dep
(`key != "-"`) must already be published. A consumer that fetched those
artifacts embeds their canonical build_ids, which a derivation reproduces by
fetching the same keys; an unpublished keyable dep means the consumer
compiled it locally, baking a build_id into the wanted key that no other
process can reproduce. (Unkeyable `-` deps are stdlibs and the like, whose
build_ids ship with the julia build. The one taint this misses — a locally
compiled *unkeyable* extension — is caught by the client's own X-Nohold,
which knows cachefile provenance.)
"""
want_derivable(ctx::FarmCtx, ns::AbstractString, want) =
    all(d -> d.key == "-" || get_kv(ctx, ns, d.uuid, d.key) !== nothing, want.deps)

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
    created = try
        aws_retry() do
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
                    "blocked" => 0,
                    "rearms" => 0,
                    "created_at" => isodate(),
                    # the send lease: re-arm may re-send the message once this
                    # is older than the claim window (see rearm_derivation!)
                    "enqueued_at" => isodate())), ctx.cfg.jobs_table,
                Dict("ConditionExpression" => "attribute_not_exists(run_id)");
                aws_config=ctx.aws)
        end
        true
    catch err
        is_conditional_failure(err) || rethrow()
        false
    end
    if created
        # the message is this job's liveness: send it before anything
        # best-effort can fail. A death right here leaves a pending item whose
        # enqueued_at lease expires, after which any holder or later want
        # re-sends (rearm_derivation!) — never a permanent zombie.
        enqueue_jobs(ctx, [JobRef(run_id, "deriv", key)]; queue_url=deriv_queue(ctx.cfg))
        # run counters are observability only and this row is hot (every
        # completing derivation transacts on it): they must never gate the
        # message, and a conflict here must never poison the ingest
        try
            aws_retry() do
                Dynamodb.update_item(ddb_item(Dict("run_id" => run_id)), ctx.cfg.runs_table,
                    Dict("UpdateExpression" => "SET #s = :active REMOVE finished_at ADD total_jobs :one",
                         "ExpressionAttributeNames" => Dict("#s" => "status"),
                         "ExpressionAttributeValues" => ddb_item(Dict(":active" => "active", ":one" => 1)));
                    aws_config=ctx.aws)
            end
        catch err
            @warn "deriv run counter update failed (observability only)" run_id err
        end
        @info "derivation enqueued" ns want.name want.version key=first(key, 12)
        return key
    end
    # the item already exists. A dead earlier derivation of the same context
    # must not tombstone the want forever: a fresh want re-arms it (its
    # missing rungs may exist by now). In-flight/succeeded items stay
    # untouched. Note: re-running a previously-counted job drifts the deriv
    # run's completion counters, which are observability-only.
    rearmed_dead = try
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => run_id, "job_key" => job_key("deriv", key))),
            ctx.cfg.jobs_table,
            Dict("ConditionExpression" => "#s IN (:uns, :err)",
                 "UpdateExpression" => "SET #s = :pending, attempts = :zero, blocked = :zero, rearms = :zero, enqueued_at = :now",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":uns" => "unsealable", ":err" => "error",
                     ":pending" => "pending", ":zero" => 0, ":now" => isodate())));
            aws_config=ctx.aws)
        true
    catch err
        is_conditional_failure(err) || rethrow()
        false
    end
    if rearmed_dead
        enqueue_jobs(ctx, [JobRef(run_id, "deriv", key)]; queue_url=deriv_queue(ctx.cfg))
        @info "re-armed dead derivation" ns want.name key=first(key, 12)
        return key
    end
    # pending/running/sealed: normally live elsewhere — but a pending item
    # whose send lease expired unclaimed (ingester died between create and
    # send, message DLQ'd/expired) has no live message, and nothing but us
    # knows it needs one
    zombie = get_seal_item(ctx, JobRef(run_id, "deriv", key))
    zombie !== nothing && rearm_derivation!(ctx, run_id, key, zombie) && return key
    return nothing
end

# How long a pending derivation may sit unclaimed before its message is
# presumed lost (also the re-send lease period), and how long a running one
# may sit unfinished before its worker *and* SQS redelivery are presumed dead
# (the heartbeat cap is 3h and redelivery adds a 30-minute visibility window,
# so 4h is beyond any legitimate lifetime). The pending window must cover
# honest queue *wait* during cascade bursts, not just delivery: at 5 minutes
# a few-thousand-deep seal queue made holders re-arm derivations that were
# merely in line, flooding the queue with duplicates.
const REARM_PENDING_AFTER = Dates.Second(15 * 60)
const REARM_RUNNING_AFTER = Dates.Second(4 * 3600)

"""
Re-send the queue message of a derivation that shows no sign of life: still
`pending` past the claim window (a crash between item creation and message
send, an expired or dead-lettered message), or still `running` past any
legitimate worker lifetime.

Retries back off exponentially — the wait doubles with every re-send
(`REARM_PENDING_AFTER × 2^rearms`, capped) — because a fixed lease turns
queue congestion into congestion collapse: when honest queue wait exceeds
the lease, every pending derivation reads as "stalled", and the re-sends
amplify the very backlog they misread (seen live twice, at 5 and then 15
minutes: a few-thousand-deep seal queue with ~100 duplicate sends/minute
fleet-wide). Backoff bounds duplicates logarithmically in wait time while
true losses still heal on the first window.

The CAS is optimistic on the exact `enqueued_at` the caller observed, so
concurrent healers elect exactly one sender and the counter never
double-bumps; a healer dying between its CAS and its send only delays the
next election by one (doubled) window. Duplicate messages are dropped at
claim time, so over-sending is waste, never corruption.
"""
function rearm_derivation!(ctx::FarmCtx, run_id::AbstractString, key::AbstractString,
                           item::AbstractDict)
    status = String(get(item, "status", ""))
    status in ("pending", "running") || return false
    now = Dates.now(UTC)
    if status == "running"
        String(get(item, "started_at", "")) < isodate(now - REARM_RUNNING_AFTER) || return false
    end
    rearms = Int(get(item, "rearms", 0))
    seen = String(get(item, "enqueued_at", ""))
    cutoff = isodate(now - REARM_PENDING_AFTER * 2^min(rearms, 5))
    (isempty(seen) || seen < cutoff) || return false
    won = try
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => run_id, "job_key" => job_key("deriv", key))),
            ctx.cfg.jobs_table,
            Dict("ConditionExpression" => "#s = :status AND " *
                     (isempty(seen) ? "attribute_not_exists(enqueued_at)" : "enqueued_at = :seen"),
                 "UpdateExpression" => "SET enqueued_at = :now ADD rearms :one",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":status" => status, ":now" => isodate(now), ":one" => 1,
                     (isempty(seen) ? () : ((":seen" => seen),))...)));
            aws_config=ctx.aws)
        true
    catch err
        is_conditional_failure(err) || rethrow()
        false
    end
    won || return false
    enqueue_jobs(ctx, [JobRef(run_id, "deriv", key)]; queue_url=deriv_queue(ctx.cfg))
    @info "re-armed stalled derivation" run_id status rearms=rearms + 1 key=first(key, 12)
    return true
end

"Whether a uuid string carries uuid5's forced version-5 and IETF-variant bits
(Base's extension-uuid derivation sets both; a registry v4 uuid never does)."
function is_uuid5_shaped(uuid::AbstractString)
    u = try
        UInt128(UUID(uuid))
    catch
        return false
    end
    return (u >> 76) & 0xf == 0x5 && (u >> 62) & 0x3 == 0x2
end

"Whether a uuid names a registry package (the extension-parent trust check)."
function registry_has_uuid(registry_dir::AbstractString, uuid::AbstractString)
    registry = try
        TOML.parsefile(joinpath(registry_dir, "Registry.toml"))
    catch
        return false
    end
    return any(lowercase(String(u)) == lowercase(uuid)
               for u in keys(get(registry, "packages", Dict())))
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
    _publish_entry!(ctx, seal_id, export_dir, unit, lowercase(unit_uuid), entry) ||
        return false
    # the unit's extensions ride on its authority: ext_of must be the unit
    # itself, and the claimed uuid must be uuid5-shaped (the exact value is
    # only computable by the julia that derived it — see parse_want_preimage;
    # the sha256 key binds the whole preimage either way)
    for (name, e) in data
        name == unit && continue
        e isa AbstractDict || continue
        lowercase(String(get(e, "ext_of", ""))) == lowercase(unit_uuid) || continue
        ext_uuid = lowercase(String(get(e, "uuid", "")))
        is_uuid5_shaped(ext_uuid) || continue
        _publish_entry!(ctx, seal_id, export_dir, String(name), ext_uuid, e) ||
            @warn "extension publication failed" unit ext=name
    end
    return true
end

function _publish_entry!(ctx::FarmCtx, seal_id::AbstractString, export_dir::AbstractString,
                         unit::AbstractString, unit_uuid::AbstractString, entry)
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
                "ext_of" => lowercase(String(get(entry, "ext_of", ""))),
                # the exact preimage this artifact was produced under: purely
                # diagnostic (keys already bind it), but it makes an inexact
                # reproduction diffable line-by-line against the wanted one
                "preimage" => String(get(entry, "preimage", "")),
                "version" => String(get(entry, "version", "-")),
                "vdir" => rel[1], "ji" => basename(ji_path),
                "so" => so_path === nothing ? "" : basename(so_path),
                "deps" => deps)
    put_sealed_object(ctx, object_key * ".meta",
                      Vector{UInt8}(codeunits(JSON.json(meta)));
                      content_type="application/json")
    return true
end
