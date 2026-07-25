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
    ctx, user = farm_ctx(; broker, role="worker")
    @info "worker started" user ninstances host=gethostname()

    draining = Ref(false)
    run_cache = Dict{String,Dict{String,Any}}()    # run_id -> parsed run item
    run_cache_lock = ReentrantLock()

    slots = map(1:ninstances) do i
        errormonitor(@async worker_slot(ctx, i - 1, draining, run_cache, run_cache_lock;
                                        once))
    end

    try
        wait.(slots)
        @info "queue drained; exiting"
    catch err
        if err isa InterruptException || (err isa TaskFailedException &&
                                          err.task.exception isa InterruptException)
            @info "interrupted; draining running jobs (Ctrl-C again to abort)"
            draining[] = true
            wait.(slots)
        else
            rethrow()
        end
    end
end

function worker_slot(ctx::FarmCtx, cpu::Int, draining::Ref{Bool},
                     run_cache, run_cache_lock; once::Bool=false)
    idle_polls = 0
    while !draining[]
        claimed = try
            claim_job(ctx)
        catch err
            @error "failed to poll the queue; backing off" slot=cpu exception=(err, catch_backtrace())
            sleep(30)
            continue
        end
        if claimed === nothing
            idle_polls += 1
            once && idle_polls >= 3 && return
            continue
        end
        idle_polls = 0
        process_job(ctx, claimed, cpu, run_cache, run_cache_lock)
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

function process_job(ctx::FarmCtx, claimed::ClaimedJob, cpu::Int,
                     run_cache, run_cache_lock)
    job = claimed.job
    @info "evaluating" job.run_id job.config job.package attempt=claimed.attempts slot=cpu

    # keep the message invisible while we work; a dead worker stops heartbeating and
    # the job is redelivered
    heartbeat_task = @async begin
        while true
            sleep(HEARTBEAT_INTERVAL)
            try
                heartbeat(ctx, claimed)
            catch err
                @warn "heartbeat failed" job.package err
            end
        end
    end

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
            schedule(heartbeat_task, InterruptException(); error=true)
            release_job(ctx, claimed)
            return
        end
    finally
        istaskdone(heartbeat_task) || schedule(heartbeat_task, InterruptException(); error=true)
    end

    try
        record_result(ctx, claimed, result)
        @info "finished" job.package result.status result.reason
    catch err
        @error "failed to record result; job will be retried" job.package exception=(err, catch_backtrace())
        release_job(ctx, claimed)
    end
end
