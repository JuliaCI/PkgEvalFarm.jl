# The worker daemon: pulls jobs from the queue and evaluates them with PkgEval.
#
# Workers are stateless: all durable state lives in DynamoDB/S3, and a worker that
# dies mid-job simply stops heartbeating, so the job reappears on the queue after the
# visibility timeout and is picked up elsewhere (with the package cache disabled on
# retries, in case the job's cache use was what killed the worker).

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

    draining = Ref(false)
    run_cache = Dict{String,Dict{String,Any}}()    # run_id -> parsed run item
    run_cache_lock = ReentrantLock()

    # One receiver owns the only SQS long poll; slots take claimed work from the
    # channel. A message is claimed *only* once a slot is free (the semaphore),
    # so nothing sits claimed-but-unheartbeated waiting for capacity.
    work = Channel{Any}(ninstances)
    free_slots = Base.Semaphore(ninstances)
    busy = Threads.Atomic{Int}(0)         # running jobs (for drain/protection)
    fleet = fleet_drain_init(ninstances)  # nothing outside an EC2 ASG

    slots = map(1:ninstances) do i
        errormonitor(@async begin
            for claimed in work
                try
                    if claimed isa ClaimedExpand
                        process_expand(ctx, claimed)
                    else
                        process_job(ctx, claimed, i - 1, run_cache, run_cache_lock)
                    end
                finally
                    Threads.atomic_sub!(busy, 1)
                    Base.release(free_slots)
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
                Base.acquire(free_slots)
                claimed = try
                    draining[] ? nothing : claim_job(ctx)
                catch err
                    @error "failed to poll the queue; backing off" exception=(err, catch_backtrace())
                    sleep(30)
                    nothing
                end
                if claimed === nothing
                    Base.release(free_slots)
                    idle_polls += 1
                    once && idle_polls >= 3 && break
                    continue
                end
                idle_polls = 0
                Threads.atomic_add!(busy, 1)
                put!(work, claimed)   # released by the slot that runs it
            end
        finally
            close(work)
        end
    end)

    try
        wait(receiver)
        wait.(slots)
        @info "queue drained; exiting"
    catch err
        if err isa InterruptException || (err isa TaskFailedException &&
                                          err.task.exception isa InterruptException)
            @info "interrupted; draining running jobs (Ctrl-C again to abort)"
            draining[] = true
            wait(receiver)
            wait.(slots)
        else
            rethrow()
        end
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
#     deterministic: an instance with seniority rank r (0 = oldest, by launch
#     time) drains iff backlog < r × its slot count — rank n-1 drains first,
#     rank 0 never does.
#
# Everything here is best effort: any API failure leaves the worker claiming
# and protected, which is exactly the pre-feature behavior.

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
Seniority rank of `instance_id` (0 = oldest launch) among the ASG's in-service
instances, from a DescribeAutoScalingGroups + DescribeInstances-free source:
the ASG member list itself carries no launch time, so rank falls back to
instance-id order for equal standing — deterministic is what matters, not
which tiebreak. Returns `(rank, ninstances)`.
"""
function fleet_rank(ctx::FarmCtx, fleet::FleetDrain)
    resp = Auto_Scaling.describe_auto_scaling_groups(
        Dict{String,Any}("AutoScalingGroupNames" => [fleet.asg]); aws_config=ctx.aws)
    group = resp["DescribeAutoScalingGroupsResult"]["AutoScalingGroups"]["member"]
    group isa AbstractVector && (group = first(group))
    members = get(group, "Instances", nothing)
    (members === nothing || !haskey(members, "member")) && return (0, 1)
    members = members["member"]
    members isa AbstractVector || (members = [members])
    # instance-id order as the seniority tiebreak: the ASG member list carries
    # no launch time, and deterministic is what matters, not which tiebreak
    ids = sort!([String(m["InstanceId"]) for m in members
                 if m["LifecycleState"] == "InService"])
    rank = something(findfirst(==(fleet.instance_id), ids), 1) - 1
    return (rank, length(ids))
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
        try
            backlog = visible_backlog(ctx)
            rank, n = fleet_rank(ctx, fleet)
            should_drain = drain_decision(backlog, rank, fleet.slots)
            if should_drain != fleet.draining
                @info(should_drain ? "draining: backlog below spare capacity" :
                                     "resuming claims", backlog, rank, n)
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

"An instance of seniority `rank` (0 = oldest) drains iff the backlog is below `rank` × slots."
drain_decision(backlog::Int, rank::Int, slots::Int) = backlog < rank * slots

"""
Ask the build-request broker (SigV4-signed Function URL; the worker's own
credentials are the authentication) to have CI build a missing Julia. The
Lambda deduplicates, so re-requesting on every retry is free. Returns whether
a request was made (or already pending).
"""
function request_julia_build(ctx::FarmCtx, miss::PkgEval.MissingStagedBuild)
    url = ctx.cfg.build_request_url
    if isempty(url)
        @error "no build-request broker configured; cannot obtain a build" miss.repo miss.sha
        return false
    end
    body = JSON.json(Dict("repo" => miss.repo, "sha" => miss.sha,
                          "variant" => miss.variant))
    uri = HTTP.URIs.URI(url)
    host = uri.host
    # lambda URLs are <id>.lambda-url.<region>.on.aws
    region = split(host, '.')[3]
    c = AWS.credentials(ctx.aws)
    headers = FarmLite.sigv4_headers(; method="POST", host=String(host), path="/",
        body, region=String(region), service="lambda",
        creds=FarmLite.AwsCreds(c.access_key_id, c.secret_key,
                                isempty(c.token) ? nothing : c.token),
        content_type="application/json")
    resp = HTTP.post(url, headers, body; status_exception=false)
    ok = resp.status in (200, 202)
    if ok
        @info "requested CI build" miss.repo sha=miss.sha[1:10] miss.variant resp.status
    else
        @error "build request failed" resp.status body=String(resp.body)[1:min(end, 300)]
    end
    return ok
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
            # compatibility needs their version numbers.
            names = intersect([Set(pkg.name for pkg in values(PkgEval.get_packages(cfg)))
                               for cfg in configs]...)
            # JLL wrappers are not worth testing (PkgEval.evaluate drops them too)
            packages = sort!([n for n in names if !endswith(n, "_jll")])
        end
        njobs = expand_run(ctx, claimed.run_id, packages)
        SQS.delete_message(ctx.cfg.queue_url, claimed.receipt_handle; aws_config=ctx.aws)
        @info "expanded run" claimed.run_id njobs
    catch err
        if err isa PkgEval.MissingStagedBuild
            # determining package compatibility needs the Julia under test; ask
            # CI to build it and retry once the queue redelivers this message.
            # The Lambda dedups, so the periodic re-request while the build runs
            # is harmless — and refreshes the ask if a build failed.
            @info "expansion needs a Julia build that is not staged" claimed.run_id sha=err.sha[1:10] err.variant
            request_julia_build(ctx, err)
            release_job(ctx, claimed; delay=BUILD_RETRY_DELAY)
        else
            @error "failed to expand run; releasing for retry" claimed.run_id exception=(err, catch_backtrace())
            release_job(ctx, claimed)
        end
    finally
        stop_heartbeat()
    end
end

"Look up (and cache) the run item, returning the `Configuration` this job refers to."
function job_config(ctx::FarmCtx, job::JobRef, run_cache, run_cache_lock)
    run = lock(run_cache_lock) do
        get!(run_cache, job.run_id) do
            get_run(ctx, job.run_id)
        end
    end
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

function process_job(ctx::FarmCtx, claimed::ClaimedJob, cpu::Int,
                     run_cache, run_cache_lock)
    job = claimed.job
    @info "evaluating" job.run_id job.config job.package attempt=claimed.attempts slot=cpu

    stop_heartbeat = start_heartbeat(ctx, claimed, job.package)

    result = try
        config = job_config(ctx, job, run_cache, run_cache_lock)
        config = PkgEval.Configuration(config; cpus=[cpu])
        # redeliveries skip the package cache: cache interactions are the most likely
        # source of irreproducible failures (mirrors evaluate()'s retry behavior)
        use_cache = claimed.attempts <= 1
        r = PkgEval.evaluate_job(config, PkgEval.Package(; name=job.package); use_cache)
        JobResult(; status=String(r.status),
                  reason=r.reason === missing ? nothing : String(r.reason),
                  version=r.version === missing ? nothing : string(r.version),
                  duration=Float64(r.duration),
                  log=r.log === missing ? nothing : String(r.log))
    catch err
        if err isa PkgEval.MissingStagedBuild
            # not a job failure: the Julia under test needs building. Ask CI
            # (deduplicated) and come back when the queue redelivers; the
            # queue's maxReceiveCount bounds how long a build may take before
            # the job lands in the DLQ, so this never loops forever.
            @info "job needs a Julia build that is not staged" job.package sha=err.sha[1:10] err.variant
            request_julia_build(ctx, err)
            release_job(ctx, claimed; delay=BUILD_RETRY_DELAY)
            return
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
