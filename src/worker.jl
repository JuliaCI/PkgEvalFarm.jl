# The worker daemon: pulls jobs from the queue and evaluates them with PkgEval.
#
# Workers are stateless: all durable state lives in DynamoDB/S3, and a worker that
# dies mid-job simply stops heartbeating, so the job reappears on the queue after the
# visibility timeout and is picked up elsewhere (with the package cache disabled on
# retries, in case the job's cache use was what killed the worker).

# Tempdirs of a worker incarnation that died uncleanly (spot reclaim, OOM,
# SIGKILL) are never removed: Base's exit-time cleanup didn't run, and the
# restarted worker mints fresh cache dirs while the orphans — whole sandbox
# homes and compilecaches — keep their disk space. Nothing else evaluates on
# this machine at startup, so every pkgeval tempdir present now is stale.
function sweep_stale_tempdirs!()
    for entry in readdir(tempdir(); join=true)
        startswith(basename(entry), "pkgeval_") || continue
        @info "removing stale tempdir" entry
        try
            isdir(entry) && PkgEval.chmod_recursive(entry, 0o777) # JuliaLang/julia#47650
            rm(entry; recursive=true, force=true)
        catch err
            @warn "could not remove stale tempdir" entry err
        end
    end
end

"""
    run_worker(; broker=nothing, ninstances=Sys.CPU_THREADS, once=false)

Evaluate jobs from the farm queue until interrupted. Spawns `ninstances` evaluation
slots, each pinned to one CPU (mirroring what `PkgEval.evaluate` does on a single
machine). Ctrl-C drains: running jobs finish, no new jobs are claimed. A hard kill is
also safe — unfinished jobs are redelivered by SQS.

With `once=true`, exits when the queue stays empty (useful for scale-to-zero setups
and tests).
"""
function run_worker(; broker::Union{AbstractString,Nothing}=nothing,
                    ninstances::Int=Sys.CPU_THREADS, once::Bool=false)
    # HTTP.jl pools connections *globally per socket type* (default
    # max(16, nthreads*4)), so long-lived requests can starve every other AWS
    # call in the process. We keep exactly one long poll in flight (below), but
    # give the pool headroom for the concurrent uploads slots make anyway.
    HTTP.set_default_connection_limit!(max(64, 4 * ninstances))

    ctx, user = farm_ctx(; broker, role="worker")
    # a farm worker must never sink ~30 minutes into compiling Julia: a missing
    # build surfaces as MissingStagedBuild and is requested from CI instead
    PkgEval.source_build_fallback[] = false
    @info "worker started" user ninstances host=gethostname()
    sweep_stale_tempdirs!()
    init_slot_rate!(ctx, ninstances)
    if sealing_enabled(ctx.cfg) && pkgeval_supports_seal()
        sweep_seal_cache!()
        # always up: whether any given run uses it is decided per seal run at
        # expansion (hook-carrying julia -> protocol), and an idle proxy is free
        start_seal_proxy!(ctx)
    end

    draining = Ref(false)
    run_cache = Dict{String,Dict{String,Any}}()    # run_id -> parsed run item
    run_cache_lock = ReentrantLock()

    # Donation: when the proxy holds a fetch (a sandbox suspended, zero CPU,
    # waiting on a derivation), its slot's capacity is free — spawn a bounded
    # donor that runs one piece of seal-queue work, typically the very
    # derivation being waited on. CPU pinning is shared with a blocked
    # process, so oversubscription is nominal.
    donors = Threads.Atomic{Int}(0)
    SEAL_DONOR[] = function ()
        # The budget must count PARKED donors against something: a donated job
        # that itself holds keeps its donor slot for the whole hold, and with
        # a flat ninstances cap a few waves of chained holds consume the
        # entire budget with resident-but-waiting sandboxes — donation then
        # silently stops replacing capacity (seen live: fleet at 30% CPU,
        # donor pool full, everyone parked). Each active hold licenses one
        # extra donor, bounded at 2× for memory sanity: every chain link is a
        # fully resident sandbox.
        donors[] >= ninstances + min(ACTIVE_HOLDS[], ninstances) && return
        draining[] && return
        Threads.atomic_add!(donors, 1)
        errormonitor(@async try
            donated = claim_seal_job(ctx)
            donated isa ClaimedJob &&
                process_job(ctx, donated, rand(0:max(ninstances - 1, 0)),
                            run_cache, run_cache_lock)
        catch err
            @warn "donor slot failed" err
        finally
            Threads.atomic_sub!(donors, 1)
        end)
        return
    end

    # One receiver owns the only SQS long poll; slots take claimed work from the
    # channel. A message is claimed *only* once a CPU is free (the pool below),
    # so nothing sits claimed-but-unheartbeated waiting for capacity. The pool
    # holds concrete CPU ids rather than a bare count because WIDE_PACKAGES
    # jobs pin several at once, and a cpuset needs to know *which*.
    work = Channel{Any}(ninstances)
    free_cpus = Channel{Int}(ninstances)
    foreach(c -> put!(free_cpus, c), 0:ninstances-1)
    # Seal overcommit: a seal/derive job spends a large fraction of its wall
    # clock in phases that burn no CPU — Pkg resolution, registry work, S3
    # fetches and publishes — measured at ~40% on a disk-unconstrained worker,
    # which caps utilization near 60% at one job per core. Spill tokens let
    # extra seal-queue jobs overlap those latency phases. Test jobs never run
    # on spill (their durations feed estimates and time limits, so they keep
    # exclusive cores); CPU pinning collides nominally, exactly like the
    # donor path below.
    nspill = sealing_enabled(ctx.cfg) && pkgeval_supports_seal() ?
             something(tryparse(Int, get(ENV, "PKGEVAL_SEAL_OVERCOMMIT", "")),
                       cld(ninstances, 2)) : 0
    spill_cpus = Channel{Int}(max(nspill, 1))
    foreach(c -> put!(spill_cpus, c % max(ninstances, 1)), 0:nspill-1)
    busy = Threads.Atomic{Int}(0)         # running jobs (for drain/protection)
    fleet = fleet_drain_init(ninstances)  # nothing outside an EC2 ASG

    # Fast-release on shutdown: systemd's ExecStop (and the spot-notice timer)
    # touch PKGEVAL_DRAIN_FILE; the watcher below then releases every claimed
    # message immediately (visibility 0) and exits. Without this, jobs running
    # on a dying host only redeliver after the full visibility timeout.
    active_claims = Dict{String,Any}()    # receipt handle => claimed
    claims_lock = ReentrantLock()
    drain_file = get(ENV, "PKGEVAL_DRAIN_FILE", "")
    if !isempty(drain_file)
        errormonitor(@async begin
            while !isfile(drain_file)
                sleep(2)
            end
            @info "drain requested; releasing claimed jobs and exiting"
            draining[] = true
            lock(claims_lock) do
                for claimed in values(active_claims)
                    try
                        release_job(ctx, claimed; delay=0)
                    catch err
                        @warn "failed to fast-release a job" err
                    end
                end
            end
            # the host is going away; evaluations in flight cannot finish
            exit(0)
        end)
    end

    slots = map(1:(ninstances + nspill)) do i
        errormonitor(@async begin
            for (claimed, cpus, spill) in work
                try
                    if claimed isa ClaimedExpand
                        process_expand(ctx, claimed)
                    else
                        process_job(ctx, claimed, cpus[1], run_cache, run_cache_lock;
                                    cpus)
                    end
                finally
                    lock(claims_lock) do
                        delete!(active_claims, claimed.receipt_handle)
                    end
                    Threads.atomic_sub!(busy, 1)
                    foreach(c -> put!(spill ? spill_cpus : free_cpus, c), cpus)
                end
            end
        end)
    end

    receiver = errormonitor(@async begin
        idle_polls = 0
        try
            while !draining[]
                if pause_claiming!(ctx, fleet, busy[])
                    once && break   # a draining --once worker is done
                    sleep(30)
                    continue
                end
                cpus = Int[take!(free_cpus)]
                claimed = try
                    draining[] ? nothing : claim_job(ctx)
                catch err
                    @error "failed to poll the queue; backing off" exception=(err, catch_backtrace())
                    sleep(30)
                    nothing
                end
                if claimed === nothing
                    put!(free_cpus, only(cpus))
                    idle_polls += 1
                    once && idle_polls >= 3 && break
                    continue
                end
                idle_polls = 0
                width = claimed isa ClaimedJob ? job_width(claimed.job, ninstances) : 1
                if width > 1
                    # gather the extra CPUs before dispatch — claiming pauses
                    # naturally (this is the only pool consumer), and the wait
                    # can span other jobs' remaining runtimes, so keep the
                    # message invisible throughout
                    stop_hb = start_heartbeat(ctx, claimed, claimed.job.package)
                    try
                        while length(cpus) < width && !draining[]
                            push!(cpus, take!(free_cpus))
                        end
                    finally
                        stop_hb()
                    end
                end
                Threads.atomic_add!(busy, 1)
                lock(claims_lock) do
                    active_claims[claimed.receipt_handle] = claimed
                end
                put!(work, (claimed, cpus, false))   # cpus return when the slot finishes
            end
        finally
            close(work)
        end
    end)

    # The spill companion: polls only the seal queue, with its own token pool,
    # so overcommit can never bleed into test/expand claims. Dies with `work`.
    spill_receiver = errormonitor(@async begin
        while nspill > 0 && !draining[] && isopen(work)
            cpu = take!(spill_cpus)
            claimed = try
                draining[] ? nothing : claim_seal_job(ctx)
            catch err
                @warn "spill poll failed; backing off" err
                sleep(30)
                nothing
            end
            if claimed === nothing
                put!(spill_cpus, cpu)
                sleep(3)   # claim_seal_job long-polls 1s; don't hammer an empty queue
                continue
            end
            Threads.atomic_add!(busy, 1)
            lock(claims_lock) do
                active_claims[claimed.receipt_handle] = claimed
            end
            try
                put!(work, (claimed, [cpu], true))
            catch err
                # the main receiver closed `work` while we were claiming:
                # hand the message straight back and stop
                err isa InvalidStateException || rethrow()
                Threads.atomic_sub!(busy, 1)
                lock(() -> delete!(active_claims, claimed.receipt_handle), claims_lock)
                release_job(ctx, claimed; delay=0)
                break
            end
        end
    end)

    try
        wait(receiver)
        wait(spill_receiver)
        wait.(slots)
        @info "queue drained; exiting"
    catch err
        if err isa InterruptException || (err isa TaskFailedException &&
                                          err.task.exception isa InterruptException)
            @info "interrupted; draining running jobs (Ctrl-C again to abort)"
            draining[] = true
            wait(receiver)
            wait(spill_receiver)
            wait.(slots)
        else
            rethrow()
        end
    finally
        SEAL_DONOR[] = nothing
        stop_seal_proxy!()
    end
end

## EC2 fleet coordination (enabled by PKGEVAL_ASG_NAME/PKGEVAL_INSTANCE_ID)
#
# Two cooperating mechanisms let the fleet scale down *gradually* at the end of
# a run instead of holding every instance until the last job exits:
#
#  1. Scale-in protection tracks busyness. Instances launch protected; a worker
#     with no running jobs and no claimable work removes its own protection,
#     making it — and only it — reclaimable by the idle policy (which can then
#     trigger on an empty queue alone, without waiting for in-flight jobs
#     elsewhere). Protection is restored before claiming again.
#
#  2. Consolidation: when the visible backlog is smaller than the fleet's spare
#     capacity, the *newest* instances stop claiming so the remaining work
#     concentrates on the oldest (warmest-cached) machines. Decentralized and
#     deterministic: an instance drains iff backlog < the summed slot count of
#     the instances ranked ahead of it (0 = most senior, which never drains).
#     Size-aware, so the fleet may freely mix instance sizes.
#
# Everything here is best effort: any API failure leaves the worker claiming
# and protected, which is exactly the pre-feature behavior.

## per-job cost attribution
#
# The worker prices its own slot-hours once at startup: its instance type and
# AZ (baked into the unit environment at bootstrap) name one spot pool, whose
# current price divided by this instance's slot count is what a slot-hour
# actually costs. record_result then attributes duration * rate to each job,
# and the report sums those into a run-level estimate. Job time only: idle,
# bootstrap and interruption rework are not billed to any job (a few percent).

"\$/slot-hour of this worker, or `nothing` when unpriced (non-EC2 workers)."
const SLOT_HOURLY_RATE = Ref{Union{Nothing,Float64}}(nothing)

function init_slot_rate!(ctx::FarmCtx, slots::Int)
    override = get(ENV, "PKGEVAL_SLOT_HOURLY", "")
    if !isempty(override)
        rate = tryparse(Float64, override)
        rate === nothing ? (@warn "unparsable PKGEVAL_SLOT_HOURLY" override) :
                           (SLOT_HOURLY_RATE[] = rate)
        return nothing
    end
    instance_type = get(ENV, "PKGEVAL_INSTANCE_TYPE", "")
    az = get(ENV, "PKGEVAL_AZ", "")
    (isempty(instance_type) || isempty(az) || slots <= 0) && return nothing
    try
        resp = EC2.describe_spot_price_history(Dict(
            "InstanceType" => [instance_type],
            "AvailabilityZone" => az,
            "ProductDescription" => ["Linux/UNIX"],
            "MaxResults" => 1); aws_config=ctx.aws)
        items = resp["spotPriceHistorySet"]["item"]
        item = items isa AbstractVector ? first(items) : items
        price = parse(Float64, item["spotPrice"])
        SLOT_HOURLY_RATE[] = price / slots
        @info "slot pricing enabled" instance_type az price rate=SLOT_HOURLY_RATE[]
    catch err
        # best effort: an unpriced worker just records cost-less results
        @warn "could not price this instance's slot-hours" instance_type az err
    end
    return nothing
end

Base.@kwdef mutable struct FleetDrain
    asg::String
    instance_id::String
    slots::Int
    draining::Bool = false
    protected::Bool = true    # ASG launches instances protected
    last_check::Float64 = 0.0
end

function fleet_drain_init(slots::Int)
    asg = get(ENV, "PKGEVAL_ASG_NAME", "")
    instance_id = get(ENV, "PKGEVAL_INSTANCE_ID", "")
    (isempty(asg) || isempty(instance_id)) && return nothing
    @info "fleet drain coordination enabled" asg instance_id
    FleetDrain(; asg, instance_id, slots)
end

"Visible messages across both job queues."
function visible_backlog(ctx::FarmCtx)
    total = 0
    for queue in unique([ctx.cfg.queue_url, slow_queue(ctx.cfg)])
        resp = SQS.get_queue_attributes(queue,
            Dict("AttributeNames" => ["ApproximateNumberOfMessages"]);
            aws_config=ctx.aws)
        total += parse(Int, resp["Attributes"]["ApproximateNumberOfMessages"])
    end
    return total
end

"""
Job-slot capacity of an instance type (its vCPU count): `Nxlarge` sizes are 4N
vCPUs, `xlarge` is 4, `large` is 2. Unrecognized formats fall back to `own`
(assume peers are shaped like us), which keeps the drain math sane rather than
exact on exotic fleets.
"""
function instance_slots(type::AbstractString, own::Int)
    m = match(r"\.(\d+)xlarge$", type)
    m !== nothing && return 4 * parse(Int, something(m.captures[1]))
    endswith(type, ".xlarge") && return 4
    endswith(type, ".large") && return 2
    return own
end

# The ASG reports each member's WeightedCapacity when the group weights its
# overrides (terraform weights by vCPUs); the type-derived size is the fallback
function member_slots(member, own::Int)
    weight = get(member, "WeightedCapacity", nothing)
    if weight !== nothing
        parsed = tryparse(Int, String(weight))
        parsed !== nothing && return parsed
    end
    return instance_slots(String(get(member, "InstanceType", "")), own)
end

"""
This instance's standing among the ASG's in-service instances: returns
`(slots_ahead, ninstances)`, where `slots_ahead` sums the job slots of the
members ranked ahead of it. The member list carries no launch time, so
instance-id order is the seniority tiebreak — deterministic is what matters,
not which tiebreak. An instance absent from the list (not yet in service)
counts as most senior, i.e. it never drains.
"""
function fleet_standing(ctx::FarmCtx, fleet::FleetDrain)
    resp = Auto_Scaling.describe_auto_scaling_groups(
        Dict{String,Any}("AutoScalingGroupNames" => [fleet.asg]); aws_config=ctx.aws)
    group = resp["DescribeAutoScalingGroupsResult"]["AutoScalingGroups"]["member"]
    group isa AbstractVector && (group = first(group))
    members = get(group, "Instances", nothing)
    (members === nothing || !haskey(members, "member")) && return (0, 1)
    members = members["member"]
    members isa AbstractVector || (members = [members])
    standing = sort!([(String(m["InstanceId"]), member_slots(m, fleet.slots))
                      for m in members if m["LifecycleState"] == "InService"])
    mine = findfirst(t -> t[1] == fleet.instance_id, standing)
    mine === nothing && return (0, length(standing))
    return (sum(Int[s for (_, s) in standing[1:mine-1]]; init=0), length(standing))
end

"""
Total job slots the fleet is scaled to, for the fast/slow duration cutoff
(see `duration_cutoff`). The `PKGEVAL_FLEET_SLOTS` override wins; otherwise
ask the ASG — its desired capacity is denominated in slots (instance weights
are vCPUs), bounded below by what is already in service since the kickstart
policy asks for a nominal capacity of 1. Non-fleet deployments (no ASG) and
API failures fall back to the static default; misestimates only shift jobs
between the fast and slow queues, they never break anything.
"""
function live_fleet_slots(ctx::FarmCtx)
    override = get(ENV, "PKGEVAL_FLEET_SLOTS", "")
    isempty(override) || return parse(Int, override)
    asg = get(ENV, "PKGEVAL_ASG_NAME", "")
    isempty(asg) && return DEFAULT_FLEET_SLOTS
    try
        resp = Auto_Scaling.describe_auto_scaling_groups(
            Dict{String,Any}("AutoScalingGroupNames" => [asg]); aws_config=ctx.aws)
        group = resp["DescribeAutoScalingGroupsResult"]["AutoScalingGroups"]["member"]
        group isa AbstractVector && (group = first(group))
        desired = something(tryparse(Int, String(get(group, "DesiredCapacity", "0"))), 0)
        inservice = 0
        members = get(group, "Instances", nothing)
        if members !== nothing && haskey(members, "member")
            ms = members["member"]
            ms isa AbstractVector || (ms = [ms])
            inservice = sum(Int[member_slots(m, DEFAULT_FLEET_SLOTS ÷ 4) for m in ms
                                if m["LifecycleState"] == "InService"]; init=0)
        end
        slots = max(desired, inservice)
        slots > 0 && return slots
    catch err
        @warn "could not size the fleet from the ASG; using the default" err
    end
    return DEFAULT_FLEET_SLOTS
end

set_protection(ctx::FarmCtx, fleet::FleetDrain, protected::Bool) =
    Auto_Scaling.set_instance_protection(fleet.asg, [fleet.instance_id], protected;
                                         aws_config=ctx.aws)

"""
Called by the receiver before each claim. Returns `true` when this instance
should not take new work right now. Throttled to one evaluation per minute;
manages this instance's scale-in protection as a side effect (unprotected only
while draining with zero running jobs).
"""
function pause_claiming!(ctx::FarmCtx, fleet::Union{FleetDrain,Nothing}, busy::Int)
    fleet === nothing && return false
    now = time()
    if now - fleet.last_check >= 60
        fleet.last_check = now
        heartbeat_generation(ctx)
        try
            backlog = visible_backlog(ctx)
            slots_ahead, n = fleet_standing(ctx, fleet)
            should_drain = drain_decision(backlog, slots_ahead)
            if should_drain != fleet.draining
                @info(should_drain ? "draining: backlog below spare capacity" :
                                     "resuming claims", backlog, slots_ahead, n)
                fleet.draining = should_drain
            end
        catch err
            @warn "fleet drain check failed; continuing to claim" err
            fleet.draining = false
        end
    end
    try
        if fleet.draining && busy == 0 && fleet.protected
            set_protection(ctx, fleet, false)
            fleet.protected = false
            @info "idle and draining; removed scale-in protection"
        elseif !fleet.draining && !fleet.protected
            set_protection(ctx, fleet, true)
            fleet.protected = true
            @info "restored scale-in protection"
        end
    catch err
        @warn "failed to update scale-in protection" err
    end
    return fleet.draining
end

"""
Keep the fleet-generation record (see cloud-init) marked live: while any
worker heartbeats it, newly launched instances join this generation's ref
instead of starting a new one. Best effort — a missed beat only risks a
too-early generation rollover, never breakage.
"""
function heartbeat_generation(ctx::FarmCtx)
    try
        Dynamodb.update_item(ddb_item(Dict("run_id" => "_fleet-generation")),
            ctx.cfg.runs_table,
            Dict("ConditionExpression" => "attribute_exists(#r)",
                 "UpdateExpression" => "SET heartbeat_at = :now",
                 "ExpressionAttributeNames" => Dict("#r" => "ref"),
                 "ExpressionAttributeValues" => ddb_item(Dict(":now" => isodate())));
            aws_config=ctx.aws)
    catch err
        is_conditional_failure(err) || @warn "generation heartbeat failed" err
    end
    return nothing
end

"""
An instance drains iff the backlog is below the summed slots of instances
ranked ahead of it, so while any work remains the most senior (0 ahead) keeps
claiming. An empty backlog drains everyone *including* the senior instance:
draining is also the sole gate on removing scale-in protection, and without
this clause the last instance would stay protected forever and outlive the
idle policy's scale-to-zero. If work reappears before the ASG reaps it, the
next fleet check (≤60s) re-protects and resumes claims.
"""
drain_decision(backlog::Int, slots_ahead::Int) = backlog < slots_ahead || backlog == 0

"""
Ask the build-request broker to have CI build a missing Julia, via the plain
Lambda Invoke API — the workers are AWS-credentialed already, so this is the
best-trodden auth path there is. (The original SigV4-signed Function URL
design was abandoned after assumed-role sessions were consistently 403'd by
the URL auth layer despite valid identity- and resource-policy allows — the
same signed requests from an IAM user worked. Undiagnosable from outside.)
The Lambda deduplicates, so re-requesting on every retry is free — and repeat
asks double as its polling clock: it checks the triggered build's state and
answers `build-failed` when CI gave up. Returns `(:pending, url)` while a
build is requested/underway, `(:failed, url)` when it failed (the caller
should stop waiting and surface the failure), or `(:error, nothing)` when the
ask itself could not be made (treated as pending: retry). The url is the
Buildkite build being waited on when the Lambda knows it, else `nothing`.
"""
function request_julia_build(ctx::FarmCtx, miss::PkgEval.MissingStagedBuild)
    fn = ctx.cfg.build_request_function
    if isempty(fn)
        @error "no build-request broker configured; cannot obtain a build" miss.repo miss.sha
        return (:error, nothing)
    end
    try
        # AWS.jl's RestJSON path JSON-encodes the args dict as the request
        # body verbatim (there is no raw-payload escape hatch), and for Lambda
        # the request body IS the event — so the args dict simply is the
        # BuildAsk object the handler parses
        resp = Lambda.invoke(fn, Dict{String,Any}("repo" => miss.repo, "sha" => miss.sha,
                                                  "variant" => miss.variant); aws_config=ctx.aws)
        payload = resp isa AbstractDict ? JSON.json(resp) : String(copy(resp))
        # the handler reports its own outcome as {"statusCode": ..., "body": json}
        outer = try JSON.parse(payload) catch; nothing end
        code = outer isa AbstractDict ? get(outer, "statusCode", 0) : 0
        body = outer isa AbstractDict ? get(outer, "body", "") : ""
        inner = body isa AbstractString && !isempty(body) ?
                (try JSON.parse(body) catch; nothing end) : nothing
        status = inner isa AbstractDict ? get(inner, "status", "") : ""
        url = inner isa AbstractDict ? get(inner, "url", nothing) : nothing
        bkurl = url isa AbstractString ? String(url) : nothing
        if status == "build-failed"
            @error "CI reports the build failed" miss.sha url
            return (:failed, bkurl)
        elseif code isa Integer && 200 <= code < 300
            @info "requested CI build" miss.repo sha=miss.sha[1:10] miss.variant status
            return (:pending, bkurl)
        else
            # an invoke that reaches the function but is refused is a failure
            @error "build request refused" miss.sha response=first(payload, 300)
            return (:error, nothing)
        end
    catch err
        @error "build request failed" miss.sha exception=(err, catch_backtrace())
        return (:error, nothing)
    end
end

"Compute the package set for an `expanding` run and fan out its jobs."
function process_expand(ctx::FarmCtx, claimed::ClaimedExpand)
    @info "expanding run" claimed.run_id
    stop_heartbeat = start_heartbeat(ctx, claimed, "expand $(claimed.run_id)")
    try
        run = get_run(ctx, claimed.run_id)
        packages = String.(run["packages"])
        if isempty(packages)  # "all packages": compute the selection here
            configs = config_from_dict.(run["configs"])
            # `get_packages` returns a Dict keyed by name (registry packages) or
            # uuid (stdlibs), so intersect the *names* of its values: comparing
            # Package structs would rely on their fields being egal.
            # This may download the Julia versions under test, since determining
            # compatibility needs their version numbers — so probe every config
            # before giving up on any: a run whose primary AND baseline both
            # need building must request both CI builds now (they run in
            # parallel), not discover the second one whole build later.
            sets = Set{String}[]
            misses = Tuple{String,PkgEval.MissingStagedBuild}[]
            for cfg in configs
                try
                    push!(sets, Set(pkg.name for pkg in values(PkgEval.get_packages(cfg))))
                catch err
                    err isa PkgEval.MissingStagedBuild || rethrow()
                    push!(misses, (cfg.name, err))
                end
            end
            if !isempty(misses)
                expand_missing_builds(ctx, claimed, misses)
                return
            end
            names = intersect(sets...)
            # JLL wrappers are not worth testing (PkgEval.evaluate drops them too)
            packages = sort!([n for n in names if !endswith(n, "_jll")])
        end
        njobs = expand_run(ctx, claimed.run_id, packages)
        # NB: claimed.queue_url, not cfg.queue_url — expand messages ride the
        # slow queue and receipt handles are queue-specific
        SQS.delete_message(claimed.queue_url, claimed.receipt_handle; aws_config=ctx.aws)
        @info "expanded run" claimed.run_id njobs
    catch err
        if err isa PkgEval.MissingStagedBuild
            # safety net: the probe above normally batches these ("?": the
            # throwing config is unknown here)
            expand_missing_builds(ctx, claimed, [("?", err)])
        else
            @error "failed to expand run; releasing for retry" claimed.run_id exception=(err, catch_backtrace())
            release_job(ctx, claimed)
        end
    finally
        stop_heartbeat()
    end
end

"""
Expansion blocked on unstaged Julia builds: ask CI for every missing one at
once — the builds then run in parallel, instead of the second one being
discovered a whole build later — note them on the run for the dashboard, and
retry once the queue redelivers the expand message. A build CI reports as
*failed* makes waiting pointless: fail the run with the reason (the bot
notices and tells the submitter) and retire the message.
"""
function expand_missing_builds(ctx::FarmCtx, claimed::ClaimedExpand,
                               misses::Vector{Tuple{String,PkgEval.MissingStagedBuild}})
    failures = String[]
    for (config, miss) in misses
        @info "expansion needs a Julia build that is not staged" claimed.run_id config sha=miss.sha[1:10] miss.variant
        status, bkurl = request_julia_build(ctx, miss)
        if status === :failed
            push!(failures,
                  "the Julia build for $(miss.repo)@$(miss.sha[1:10]) ($(miss.variant)) failed" *
                  (bkurl === nothing ? "" : ": $(something(bkurl))"))
        else
            note_run_waiting(ctx, claimed.run_id;
                             config, sha=miss.sha, variant=miss.variant, url=bkurl)
        end
    end
    if isempty(failures)
        release_job(ctx, claimed; delay=BUILD_RETRY_DELAY)
    else
        why = join(failures, "; ")
        @error "julia build failed; failing the run" claimed.run_id why
        fail_run(ctx, claimed.run_id, why)
        SQS.delete_message(claimed.queue_url, claimed.receipt_handle; aws_config=ctx.aws)
    end
    return nothing
end

"Look up (and cache) the run item a job belongs to."
function job_run(ctx::FarmCtx, job::JobRef, run_cache, run_cache_lock)
    lock(run_cache_lock) do
        get!(run_cache, job.run_id) do
            get_run(ctx, job.run_id)
        end
    end
end

"Look up (and cache) the run item, returning the `Configuration` this job refers to."
function job_config(ctx::FarmCtx, job::JobRef, run_cache, run_cache_lock)
    run = job_run(ctx, job, run_cache, run_cache_lock)
    config_dict = only(filter(c -> c["name"] == job.config, run["configs"]))
    return config_from_dict(config_dict)
end

# Keep the message invisible while we work; a dead worker stops heartbeating and the
# job is redelivered. Returns a function that stops the heartbeat task.
function start_heartbeat(ctx::FarmCtx, claimed, what)
    stopped = Ref(false)
    task = @async for n in 1:MAX_HEARTBEATS
        sleep(HEARTBEAT_INTERVAL)
        stopped[] && break
        try
            heartbeat(ctx, claimed)
        catch err
            @warn "heartbeat failed" what err
        end
        # Bounded on purpose: a *hung* worker (as opposed to a dead one) would
        # otherwise extend visibility forever and the job could never be
        # redelivered. Give up well past any legitimate job duration.
        n == MAX_HEARTBEATS &&
            @error "job exceeded the heartbeat limit; releasing it to the queue" what
    end
    # cooperative stop: the task checks `stopped` after each sleep, so it exits
    # within one interval without needing to be interrupted mid-request
    return function ()
        stopped[] = true
        nothing
    end
end

# Packages whose test suites parallelize to `JULIA_CPU_THREADS` (LinearAlgebra
# runs under ParallelTestRunner with --jobs=Sys.CPU_THREADS) and whose serial
# runtime (hours) would otherwise dominate every run tail: the receiver gathers
# this many CPUs from the pool before dispatching them, and the sandbox gets
# the whole set as its cpuset. Trading slot-hours for tail latency only pays
# off when the suite actually scales, so additions belong here, not in a
# duration heuristic.
const WIDE_PACKAGES = Dict("LinearAlgebra" => 8)

"CPUs a job should occupy: its WIDE_PACKAGES width, capped by the machine."
job_width(job::JobRef, ninstances::Int) =
    is_seal_job(job) || is_derivation_job(job) ? 1 :
    min(get(WIDE_PACKAGES, job.package, 1), ninstances)

function process_job(ctx::FarmCtx, claimed::ClaimedJob, cpu::Int,
                     run_cache, run_cache_lock;
                     cpus::Union{Nothing,Vector{Int}}=nothing)
    job = claimed.job
    is_derivation_job(job) &&
        return process_derivation_job(ctx, claimed, cpu, run_cache, run_cache_lock)
    is_seal_job(job) && return process_seal_job(ctx, claimed, cpu, run_cache, run_cache_lock)
    @info "evaluating" job.run_id job.config job.package attempt=claimed.attempts slot=cpu nslots=(cpus === nothing ? 1 : length(something(cpus)))

    stop_heartbeat = start_heartbeat(ctx, claimed, job.package)

    result = try
        config = job_config(ctx, job, run_cache, run_cache_lock)
        config = PkgEval.Configuration(config; cpus=something(cpus, [cpu]))
        # redeliveries skip the package cache: cache interactions are the most likely
        # source of irreproducible failures (mirrors evaluate()'s retry behavior).
        # The seal gate and cache protocol are skipped too, for the same reason.
        use_cache = claimed.attempts <= 1
        gated_seal_run = ""
        if use_cache
            run = job_run(ctx, job, run_cache, run_cache_lock)
            state, gated_seal_run = seal_state(ctx, run, job)
            state == :pending &&
                hold_and_fill!(ctx, job, gated_seal_run, cpu, run_cache, run_cache_lock)
        end
        # wall clock from here prices the slot: setup, install, precompile and
        # test all occupy it (the seal-gate wait above deliberately does not —
        # that time went to other jobs, which bill themselves)
        eval_started = time()
        sealed_kwargs = if isempty(gated_seal_run)
            (;)
        else
            seal_run = job_run(ctx, JobRef(gated_seal_run, SEAL_CONFIG_NAME, ""),
                               run_cache, run_cache_lock)
            # a seal run from a retired scheme gates nothing: run cold
            seal_run_scheme(seal_run) == "protocol" ?
                seal_protocol_kwargs(seal_id_of(gated_seal_run);
                                     fetch_deadline=test_fetch_deadline()) : (;)
        end
        r = PkgEval.evaluate_job(config, PkgEval.Package(; name=job.package);
                                 use_cache, sealed_kwargs...)
        JobResult(; status=String(r.status),
                  reason=r.reason === missing ? nothing : String(r.reason),
                  version=r.version === missing ? nothing : string(r.version),
                  duration=Float64(r.duration), wall=time() - eval_started,
                  slots=cpus === nothing ? 1 : length(something(cpus)),
                  # haskey: tolerate a PkgEval pinned before peak_rss existed
                  peak_rss=haskey(r, :peak_rss) && r.peak_rss > 0 ? Int(r.peak_rss) : nothing,
                  log=r.log === missing ? nothing : String(r.log))
    catch err
        if err isa PkgEval.MissingStagedBuild
            # not a job failure: the Julia under test needs building. Ask CI
            # (deduplicated) and come back when the queue redelivers. A build
            # CI reports as *failed* becomes an error result instead — the run
            # completes normally, with the failure in the report. The queue's
            # maxReceiveCount still bounds total build waiting as a backstop.
            @info "job needs a Julia build that is not staged" job.package sha=err.sha[1:10] err.variant
            status, bkurl = request_julia_build(ctx, err)
            if status === :failed
                @error "julia build failed; recording job error" job.package sha=err.sha[1:10]
                JobResult(; status="error", reason="julia_build_failed",
                          log="the Julia build for $(err.repo)@$(err.sha) ($(err.variant)) failed" *
                              (bkurl === nothing ? "" : "\n$(something(bkurl))"))
            else
                note_run_waiting(ctx, job.run_id;
                                 config=job.config, sha=err.sha, variant=err.variant,
                                 url=bkurl)
                release_job(ctx, claimed; delay=BUILD_RETRY_DELAY)
                return
            end
        elseif claimed.attempts >= 3
            # persistent infrastructure failure: record it so the run can finish
            @error "job errored repeatedly; giving up" job.package exception=(err, catch_backtrace())
            JobResult(; status="error", reason="worker_exception",
                      log=sprint(showerror, err, catch_backtrace()))
        else
            @error "job errored; releasing for retry" job.package exception=(err, catch_backtrace())
            release_job(ctx, claimed)
            return
        end
    finally
        stop_heartbeat()
    end

    try
        record_result(ctx, claimed, result)
        @info "finished" job.package result.status result.reason
    catch err
        @error "failed to record result; job will be retried" job.package exception=(err, catch_backtrace())
        release_job(ctx, claimed)
    end
end
