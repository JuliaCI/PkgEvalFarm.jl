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
    @info "worker started" user ninstances host=gethostname()

    draining = Ref(false)
    run_cache = Dict{String,Dict{String,Any}}()    # run_id -> parsed run item
    run_cache_lock = ReentrantLock()

    # One receiver owns the only SQS long poll; slots take claimed work from the
    # channel. A message is claimed *only* once a slot is free (the semaphore),
    # so nothing sits claimed-but-unheartbeated waiting for capacity.
    work = Channel{Any}(ninstances)
    free_slots = Base.Semaphore(ninstances)

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
                    Base.release(free_slots)
                end
            end
        end)
    end

    receiver = errormonitor(@async begin
        idle_polls = 0
        try
            while !draining[]
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

"Compute the package set for an `expanding` run and fan out its jobs."
function process_expand(ctx::FarmCtx, claimed::ClaimedExpand)
    @info "expanding run" claimed.run_id
    stop_heartbeat = start_heartbeat(ctx, claimed, "expand $(claimed.run_id)")
    try
        run = get_run(ctx, claimed.run_id)
        packages = String.(run["packages"])
        if isempty(packages)  # "all packages": compute the selection here
            configs = config_from_dict.(run["configs"])
            # may download/build the Julia versions under test to determine compatibility
            pkgs = intersect([PkgEval.get_packages(cfg) for cfg in configs]...)
            # JLL wrappers are not worth testing (PkgEval.evaluate drops them too)
            packages = [pkg.name for pkg in pkgs if !endswith(pkg.name, "_jll")]
        end
        njobs = expand_run(ctx, claimed.run_id, packages)
        SQS.delete_message(ctx.cfg.queue_url, claimed.receipt_handle; aws_config=ctx.aws)
        @info "expanded run" claimed.run_id njobs
    catch err
        @error "failed to expand run; releasing for retry" claimed.run_id exception=(err, catch_backtrace())
        release_job(ctx, claimed)
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
        if claimed.attempts >= 3
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
