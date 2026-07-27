# Run/job lifecycle against DynamoDB (state), SQS (dispatch) and S3 (logs).
#
# SQS is at-least-once, so every transition is guarded by a conditional write in
# DynamoDB: a job that is already in a terminal state is never re-run, its stray
# message is simply deleted.

# how long a claimed message stays invisible; workers heartbeat well within this
const VISIBILITY_TIMEOUT = 30 * 60
const HEARTBEAT_INTERVAL = 5 * 60
# ~3 hours: beyond any legitimate job (PkgEval's own limit is 45 min, doubled for
# slow packages), so a hung worker eventually lets its job return to the queue
const MAX_HEARTBEATS = 36

isodate(t=Dates.now(UTC)) = Dates.format(t, dateformat"yyyy-mm-dd\THH:MM:SS\Z")

aws_retry(f; n=5) = retry(f; delays=ExponentialBackOff(; n, first_delay=1, max_delay=30))()

# real AWS uses the ConditionalCheckFailedException code; some emulators only carry
# the human-readable message with a generic 400 code
is_conditional_failure(err) = err isa AWS.AWSException &&
    (occursin("ConditionalCheckFailed", err.code) ||
     occursin("conditional request failed", lowercase(err.message)))

# S3's answer to an If-None-Match: * PUT when the key already exists
is_precondition_failed(err) = err isa AWS.AWSException &&
    (err.code == "PreconditionFailed" || err.code == "412")


## submission

"""
    create_run(ctx, spec::RunSpec; submitter, run_id=new_run_id()) -> run_id

Create the run in DynamoDB (one `PutItem`) and enqueue a single *expand* message.
Job fan-out always happens on a worker via [`expand_run`](@ref): for an explicit
package list (stored on the run item) that is a mere formality, and for an empty one
("all packages") the worker computes the selection — which may require the Julia
build under test, so it cannot happen on submitters. Keeping submission this small
also lets the bot Lambda submit runs without an AWS SDK.
"""
function create_run(ctx::FarmCtx, spec::RunSpec; submitter::AbstractString,
                    run_id::AbstractString=new_run_id(), reuse::Bool=true)
    config_names = [cfg.name for cfg in spec.configs]
    allunique(config_names) || error("configuration names must be unique: $config_names")

    Dynamodb.put_item(ddb_item(Dict(
            "run_id" => run_id,
            "created_at" => isodate(),
            "submitter" => String(submitter),
            "status" => "expanding",
            "configs" => JSON.json(config_to_dict.(spec.configs)),
            "packages" => JSON.json(spec.packages),  # empty = all compatible packages
            "context" => JSON.json(spec.context),
            "total_jobs" => 0,
            "completed_jobs" => 0,
            # baseline reuse (expand_run); false = the submitter wants a fresh
            # evaluation of the against side even if matching results exist
            "reuse" => reuse,
        )), ctx.cfg.runs_table,
        Dict("ConditionExpression" => "attribute_not_exists(run_id)");
        aws_config=ctx.aws)

    aws_retry() do
        SQS.send_message(JSON.json(Dict("run_id" => run_id, "expand" => true)),
                         slow_queue(ctx.cfg); aws_config=ctx.aws)
    end
    return run_id
end

# packages with no history are estimated at PkgEval's default time limit: the
# conservative direction, since an unknown straggler scheduled early costs
# nothing while one scheduled late costs the whole tail
const DEFAULT_DURATION_ESTIMATE = 45.0 * 60

# assumed fleet slot capacity for the cutoff computation (overridable per
# deployment). Overestimating pushes the cutoff up (more jobs classed slow) —
# again the conservative direction.
fleet_slots() = parse(Int, get(ENV, "PKGEVAL_FLEET_SLOTS", "128"))

"Completed runs, newest first, as `(created_at, run_id, configs)` tuples."
function completed_runs(ctx::FarmCtx)
    runs = Tuple{String,String,Any}[]
    start_key = nothing
    while true
        params = Dict{String,Any}(
            "FilterExpression" => "#s = :done",
            "ExpressionAttributeNames" => Dict("#s" => "status"),
            "ExpressionAttributeValues" => ddb_item(Dict(":done" => "done")),
            "ProjectionExpression" => "run_id, created_at, configs")
        start_key === nothing || (params["ExclusiveStartKey"] = start_key)
        resp = aws_retry() do
            Dynamodb.scan(ctx.cfg.runs_table, params; aws_config=ctx.aws)
        end
        for item in ddb_parse.(resp["Items"])
            push!(runs, (String(get(item, "created_at", "")), String(item["run_id"]),
                         JSON.parse(item["configs"])))
        end
        start_key = get(resp, "LastEvaluatedKey", nothing)
        start_key === nothing && break
    end
    return sort!(runs; rev=true)
end

"""
Per-package duration estimates from recent completed runs (newest first, up to
`max_donors` of them). Duration is mostly package-intrinsic, so estimates
transfer across Julia versions where results would not; the max over configs
and donors is used, since underestimating is what causes stragglers.
"""
function duration_estimates(ctx::FarmCtx, packages::Vector{String},
                            donors::Vector{<:Tuple}; max_donors::Int=3)
    est = Dict{String,Float64}()
    wanted = Set(packages)
    for (_, donor_id, _) in first(donors, max_donors)
        length(est) == length(wanted) && break
        for job in run_jobs(ctx, donor_id)
            pkg = String(job["package"])
            pkg in wanted || continue
            get(job, "status", "") in TERMINAL_STATUSES || continue
            get(job, "status", "") == "error" && continue
            duration = Float64(get(job, "duration", 0.0))
            duration > 0 || continue
            est[pkg] = max(get(est, pkg, 0.0), duration)
        end
    end
    return est
end

"""
Duration above which a job goes to the slow queue, chosen from the run's own
mix: the smallest cutoff such that the fast class still holds `margin` × (the
longest estimated job) × (fleet slot capacity) of aggregate work. The cutoff
directly bounds the end-of-run tail (once only the fast queue remains, no
machine is extended by more than one fast job), while the backfill condition
guarantees every slow job — claimed in whatever order SQS feels like — starts
with enough short work queued behind it. Runs too small to satisfy the
condition get `Inf`: a single class, since there is nothing to backfill with.
"""
function duration_cutoff(estimates::Vector{Float64}; slots::Int=fleet_slots(),
                         margin::Float64=2.0)
    isempty(estimates) && return Inf
    need = margin * maximum(estimates) * slots
    acc = 0.0
    for d in sort(estimates)
        acc += d
        acc >= need && return d
    end
    return Inf
end

"""
Find reusable baseline results for a run: the `against` config's jobs, taken
from the most recent `done` run containing a config with the same content
fingerprint. Reuse is sound only when the julia spec is immutable (exact sha or
release tag) — the bot pins branch specs to shas at submission for this reason
— and the submitter can veto it (`reuse = false` / `--fresh-baseline`) when the
existing baseline looks flaky.

Returns `(config_name, donor_run_id, Dict(package => donor job item))`, with an
empty dict when there is nothing to reuse. Infrastructure failures ("error")
are never reused; real results (including fail/crash/kill) are.
"""
function baseline_reuse_plan(ctx::FarmCtx, run::AbstractDict, packages::Vector{String},
                             completed::Vector{<:Tuple}=completed_runs(ctx))
    none = ("", "", Dict{String,Dict{String,Any}}())
    get(run, "reuse", true) == true || return none
    i = findfirst(c -> c["name"] == "against", run["configs"])
    i === nothing && return none
    against = run["configs"][i]
    reusable_julia_spec(String(against["julia"])) || return none
    fp = config_fingerprint(against)

    donors = Tuple{String,String,String}[]  # (created_at, run_id, config name)
    for (created_at, run_id, configs) in completed
        run_id == run["run_id"] && continue
        for cfg in configs
            config_fingerprint(cfg) == fp || continue
            push!(donors, (created_at, run_id, String(cfg["name"])))
        end
    end
    isempty(donors) && return none

    wanted = Set(packages)
    for (_, donor_id, donor_cfg) in donors
        results = Dict{String,Dict{String,Any}}()
        for job in run_jobs(ctx, donor_id)
            job["config"] == donor_cfg || continue
            job["package"] in wanted || continue
            status = get(job, "status", "")
            status in TERMINAL_STATUSES && status != "error" || continue
            results[String(job["package"])] = job
        end
        isempty(results) || return ("against", donor_id, results)
    end
    return none
end

"Write already-completed job items carrying a donor's results (batched)."
function write_reused_jobs(ctx::FarmCtx, run_id::AbstractString, donor_id::AbstractString,
                           jobs::Vector{JobRef}, results::AbstractDict)
    now = isodate()
    for batch in Iterators.partition(jobs, 25)
        requests = map(batch) do job
            donor = results[job.package]
            Dict("PutRequest" => Dict("Item" => ddb_item(Dict(
                "run_id" => job.run_id,
                "job_key" => job_key(job),
                "config" => job.config,
                "package" => job.package,
                "status" => donor["status"],
                "reason" => get(donor, "reason", nothing),
                "reason_message" => get(donor, "reason_message", nothing),
                "version" => get(donor, "version", nothing),
                "duration" => get(donor, "duration", 0.0),
                # the donor's log verbatim: log_key is stored per job precisely
                # so a result can point outside its own run's prefix
                "log_key" => get(donor, "log_key", nothing),
                "reused_from" => donor_id,
                "finished_at" => now,
                "attempts" => 0))))
        end
        aws_retry() do
            resp = Dynamodb.batch_write_item(Dict(ctx.cfg.jobs_table => collect(requests));
                                             aws_config=ctx.aws)
            unprocessed = get(resp, "UnprocessedItems", Dict())
            isempty(unprocessed) || error("unprocessed DynamoDB writes; retrying")
        end
    end
end

"Create the DynamoDB job items (25 per BatchWriteItem), idempotently."
function write_jobs(ctx::FarmCtx, jobs::Vector{JobRef})
    for batch in Iterators.partition(jobs, 25)
        requests = [Dict("PutRequest" => Dict("Item" => ddb_item(Dict(
                        "run_id" => job.run_id,
                        "job_key" => job_key(job),
                        "config" => job.config,
                        "package" => job.package,
                        "status" => "pending",
                        "attempts" => 0,
                    )))) for job in batch]
        aws_retry() do
            resp = Dynamodb.batch_write_item(Dict(ctx.cfg.jobs_table => requests);
                                             aws_config=ctx.aws)
            unprocessed = get(resp, "UnprocessedItems", Dict())
            isempty(unprocessed) || error("unprocessed DynamoDB writes; retrying")
        end
    end
end

"""
    expand_run(ctx, run_id, packages) -> njobs

Worker-side completion of an `expanding` run: write the job items, flip the run to
`active` with the real job count, and enqueue the job messages.

Safe under at-least-once delivery: job items are written before the conditional
status flip, so a crashed expansion is simply redone, and because duplicate job
messages are harmless, a redelivered expand message after the flip just re-enqueues.
"""
function expand_run(ctx::FarmCtx, run_id::AbstractString, packages::Vector{String})
    run = get_run(ctx, run_id)
    # a stray expand message for a finished run must not re-enqueue its jobs
    run["status"] == "done" && return run["total_jobs"]
    config_names = [String(c["name"]) for c in run["configs"]]
    jobs = [JobRef(run_id, cfg, pkg) for cfg in config_names for pkg in packages]
    isempty(jobs) && error("expansion of $run_id produced no jobs")

    completed = completed_runs(ctx)

    # baseline reuse: against-side jobs with a matching prior result are written
    # pre-completed (pointing at the donor's log) and never enqueued
    reuse_cfg, donor_id, reused_results = baseline_reuse_plan(ctx, run, packages, completed)
    reused = [j for j in jobs if j.config == reuse_cfg && haskey(reused_results, j.package)]
    fresh = setdiff(jobs, reused)
    isempty(reused) || @info "reusing baseline results" run_id donor_id n=length(reused)

    # straggler avoidance: jobs above the (run-mix-derived) duration cutoff go
    # to the slow queue, which workers drain first
    est = duration_estimates(ctx, [j.package for j in fresh], completed)
    job_est(j) = get(est, j.package, DEFAULT_DURATION_ESTIMATE)
    cutoff = duration_cutoff([job_est(j) for j in fresh])
    is_slow(j) = job_est(j) > cutoff

    # don't rewrite (= reset) job items once the run went active — after that point a
    # redelivered expand message only needs to make sure the messages went out
    if run["status"] == "expanding"
        write_jobs(ctx, fresh)
        isempty(reused) || write_reused_jobs(ctx, run_id, donor_id, reused, reused_results)
    end
    try
        Dynamodb.update_item(ddb_item(Dict("run_id" => run_id)), ctx.cfg.runs_table,
            Dict("ConditionExpression" => "#s = :expanding",
                 "UpdateExpression" => "SET #s = :active, total_jobs = :total, " *
                                       "completed_jobs = :reused",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":expanding" => "expanding", ":active" => "active",
                     ":total" => length(jobs), ":reused" => length(reused))));
            aws_config=ctx.aws)
    catch err
        if is_conditional_failure(err)
            # already expanded by an earlier (interrupted) attempt; messages may or
            # may not have been sent, so fall through and (re-)enqueue everything —
            # claim_job drops messages for jobs that are already completed (which
            # covers the reused ones), so over-enqueueing is merely a little churn
            fresh = jobs
        else
            rethrow()
        end
    end
    slow_jobs = [j for j in fresh if is_slow(j)]
    fast_jobs = [j for j in fresh if !is_slow(j)]
    isempty(slow_jobs) ||
        @info "routing long jobs to the slow queue" run_id nslow=length(slow_jobs) cutoff
    enqueue_jobs(ctx, slow_jobs; queue_url=slow_queue(ctx.cfg))
    enqueue_jobs(ctx, fast_jobs)
    return length(jobs)
end

"Enqueue SQS messages for jobs (also used to re-drive stalled jobs)."
function enqueue_jobs(ctx::FarmCtx, jobs::Vector{JobRef};
                      queue_url::AbstractString=ctx.cfg.queue_url)
    for batch in Iterators.partition(jobs, 10)
        entries = [Dict("Id" => string(i), "MessageBody" => json_message(job))
                   for (i, job) in enumerate(batch)]
        aws_retry() do
            resp = SQS.send_message_batch(entries, queue_url; aws_config=ctx.aws)
            failed = get(resp, "Failed", nothing)
            failed === nothing || isempty(failed) || error("failed to enqueue $(length(failed)) messages; retrying")
        end
    end
end


## claiming and completing (worker side)

struct ClaimedJob
    job::JobRef
    receipt_handle::String
    attempts::Int
    queue_url::String   # receipt handles are queue-specific
end

"A received *expand* message: the worker should compute and fan out the run's jobs."
struct ClaimedExpand
    run_id::String
    receipt_handle::String
    queue_url::String
end

"""
    claim_job(ctx; wait=20) -> Union{ClaimedJob,Nothing}

Long-poll the queue for one job and transition it to `running`. Returns `nothing` if
the queue was empty or the received job turned out to be already finished (its stray
duplicate message is deleted).
"""
function claim_job(ctx::FarmCtx; wait::Int=20)
    # Slow jobs first: the whole point of the second queue is that long jobs
    # must start while short work remains to backfill behind them, and queue
    # priority is the only ordering SQS actually honors. WaitTimeSeconds=1 is
    # still a long poll (it consults every storage host, unlike wait=0 which
    # samples and can miss), so an "empty" answer is trustworthy.
    slow = slow_queue(ctx.cfg)
    queues = slow == ctx.cfg.queue_url ?
        ((ctx.cfg.queue_url, wait),) : ((slow, 1), (ctx.cfg.queue_url, wait))
    message, from_queue = nothing, ""
    for (queue, w) in queues
        resp = SQS.receive_message(queue,
            Dict("WaitTimeSeconds" => w, "MaxNumberOfMessages" => 1,
                 "VisibilityTimeout" => VISIBILITY_TIMEOUT,
                 "AttributeNames" => ["ApproximateReceiveCount"]);
            aws_config=ctx.aws)
        messages = get(resp, "Messages", nothing)
        (messages === nothing || isempty(messages)) && continue
        message, from_queue = only(messages), queue
        break
    end
    message === nothing && return nothing
    receipt = message["ReceiptHandle"]
    body = JSON.parse(message["Body"])
    get(body, "expand", false) == true &&
        return ClaimedExpand(body["run_id"], receipt, from_queue)
    job = JobRef(body)
    receive_count = parse(Int, get(get(message, "Attributes", Dict()), "ApproximateReceiveCount", "1"))

    # flip pending/running -> running; fails if the job is already done
    try
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => job.run_id, "job_key" => job_key(job))),
            ctx.cfg.jobs_table,
            Dict("ConditionExpression" => "attribute_exists(run_id) AND #s IN (:pending, :running)",
                 "UpdateExpression" => "SET #s = :running, worker = :worker, started_at = :now ADD attempts :one",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":pending" => "pending", ":running" => "running",
                     ":worker" => worker_identity(), ":now" => isodate(), ":one" => 1)));
            aws_config=ctx.aws)
    catch err
        if is_conditional_failure(err)
            # already finished (duplicate delivery), or the run item was deleted
            SQS.delete_message(from_queue, receipt; aws_config=ctx.aws)
            return nothing
        end
        rethrow()
    end
    return ClaimedJob(job, receipt, receive_count, from_queue)
end

worker_identity() = string(get(ENV, "USER", "unknown"), "@", gethostname())

"Extend the message visibility while the job is still being evaluated."
heartbeat(ctx::FarmCtx, claimed::Union{ClaimedJob,ClaimedExpand};
          extend::Int=VISIBILITY_TIMEOUT) =
    SQS.change_message_visibility(claimed.queue_url, claimed.receipt_handle, extend;
                                  aws_config=ctx.aws)

"Give up on a claimed job without recording a result; it will be redelivered."
function release_job(ctx::FarmCtx, claimed::Union{ClaimedJob,ClaimedExpand}; delay::Int=60)
    try
        SQS.change_message_visibility(claimed.queue_url, claimed.receipt_handle, delay;
                                      aws_config=ctx.aws)
    catch err
        @warn "failed to release job; it will reappear after the visibility timeout" err
    end
end

"""
    record_result(ctx, claimed, result::JobResult)

Upload the log to S3, mark the job finished in DynamoDB, bump the run's completion
counter (flipping the run to `done` on the last job), and delete the SQS message.
"""
function record_result(ctx::FarmCtx, claimed::ClaimedJob, result::JobResult)
    job = claimed.job
    result.status in TERMINAL_STATUSES || error("not a terminal status: $(result.status)")

    key = log_key(job.run_id, job.config, job.package)
    if result.log !== nothing
        aws_retry() do
            try
                # If-None-Match makes the upload create-only (and the bucket
                # policy *requires* workers to send it): first write wins, so an
                # already-recorded log can never be overwritten later
                S3.put_object(ctx.cfg.bucket, key,
                    Dict("body" => result.log,
                         "headers" => Dict("Content-Type" => "text/plain; charset=utf-8",
                                           "If-None-Match" => "*"));
                    aws_config=ctx.aws)
            catch err
                # a crashed earlier attempt already uploaded this job's log
                is_precondition_failed(err) || rethrow()
            end
        end
    end

    aws_retry() do
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => job.run_id, "job_key" => job_key(job))),
            ctx.cfg.jobs_table,
            Dict("ConditionExpression" => "#s = :running",
                 "UpdateExpression" => "SET #s = :status, reason = :reason, " *
                                       "reason_message = :reason_message, version = :version, " *
                                       "#d = :duration, finished_at = :now, log_key = :log_key",
                 "ExpressionAttributeNames" => Dict("#s" => "status", "#d" => "duration"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":running" => "running", ":status" => result.status,
                     ":reason" => result.reason,
                     # store the human-readable description so report generation
                     # doesn't need PkgEval's reason table (the bot Lambda lacks it)
                     ":reason_message" => result.reason === nothing ? nothing :
                                          reason_message(result.reason),
                     ":version" => result.version,
                     ":duration" => result.duration, ":now" => isodate(),
                     ":log_key" => result.log === nothing ? nothing : key)));
            aws_config=ctx.aws)
    end

    # bump the run's completion counter; the worker finishing the last job marks it done
    resp = aws_retry() do
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => job.run_id)), ctx.cfg.runs_table,
            Dict("UpdateExpression" => "ADD completed_jobs :one",
                 "ExpressionAttributeValues" => ddb_item(Dict(":one" => 1)),
                 "ReturnValues" => "ALL_NEW");
            aws_config=ctx.aws)
    end
    attrs = ddb_parse(resp["Attributes"])
    if attrs["completed_jobs"] >= attrs["total_jobs"] && attrs["status"] == "active"
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => job.run_id)), ctx.cfg.runs_table,
            Dict("ConditionExpression" => "#s = :active AND completed_jobs >= total_jobs",
                 "UpdateExpression" => "SET #s = :done, finished_at = :now",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":active" => "active", ":done" => "done", ":now" => isodate())));
            aws_config=ctx.aws)
    end

    SQS.delete_message(claimed.queue_url, claimed.receipt_handle; aws_config=ctx.aws)
    return nothing
end


## inspection (submitter/report side)

function get_run(ctx::FarmCtx, run_id::AbstractString)
    resp = Dynamodb.get_item(ddb_item(Dict("run_id" => run_id)), ctx.cfg.runs_table;
                             aws_config=ctx.aws)
    haskey(resp, "Item") || error("no such run: $run_id")
    run = ddb_parse(resp["Item"])
    run["configs"] = JSON.parse(run["configs"])
    run["context"] = JSON.parse(run["context"])
    run["packages"] = JSON.parse(get(run, "packages", "[]"))
    return run
end

"All job items of a run (paginated DynamoDB query)."
function run_jobs(ctx::FarmCtx, run_id::AbstractString)
    jobs = Dict{String,Any}[]
    start_key = nothing
    while true
        params = Dict{String,Any}(
            "KeyConditionExpression" => "run_id = :run_id",
            "ExpressionAttributeValues" => ddb_item(Dict(":run_id" => run_id)))
        start_key === nothing || (params["ExclusiveStartKey"] = start_key)
        resp = aws_retry() do
            Dynamodb.query(ctx.cfg.jobs_table, params; aws_config=ctx.aws)
        end
        append!(jobs, ddb_parse.(resp["Items"]))
        start_key = get(resp, "LastEvaluatedKey", nothing)
        start_key === nothing && break
    end
    return jobs
end

"Fetch a job log from S3, or `nothing` if the job didn't upload one."
function job_log(ctx::FarmCtx, job::AbstractDict)
    key = get(job, "log_key", nothing)
    key === nothing && return nothing
    resp = S3.get_object(ctx.cfg.bucket, key, Dict("return_raw" => true); aws_config=ctx.aws)
    return String(copy(resp))
end
