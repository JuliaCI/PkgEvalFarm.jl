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
                    run_id::AbstractString=new_run_id())
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
        )), ctx.cfg.runs_table,
        Dict("ConditionExpression" => "attribute_not_exists(run_id)");
        aws_config=ctx.aws)

    aws_retry() do
        SQS.send_message(JSON.json(Dict("run_id" => run_id, "expand" => true)),
                         ctx.cfg.queue_url; aws_config=ctx.aws)
    end
    return run_id
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

    # don't rewrite (= reset) job items once the run went active — after that point a
    # redelivered expand message only needs to make sure the messages went out
    run["status"] == "expanding" && write_jobs(ctx, jobs)
    try
        Dynamodb.update_item(ddb_item(Dict("run_id" => run_id)), ctx.cfg.runs_table,
            Dict("ConditionExpression" => "#s = :expanding",
                 "UpdateExpression" => "SET #s = :active, total_jobs = :total",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":expanding" => "expanding", ":active" => "active",
                     ":total" => length(jobs))));
            aws_config=ctx.aws)
    catch err
        if is_conditional_failure(err)
            # already expanded by an earlier (interrupted) attempt; messages may or
            # may not have been sent, so fall through and (re-)enqueue everything
        else
            rethrow()
        end
    end
    enqueue_jobs(ctx, jobs)
    return length(jobs)
end

"Enqueue SQS messages for jobs (also used to re-drive stalled jobs)."
function enqueue_jobs(ctx::FarmCtx, jobs::Vector{JobRef})
    for batch in Iterators.partition(jobs, 10)
        entries = [Dict("Id" => string(i), "MessageBody" => json_message(job))
                   for (i, job) in enumerate(batch)]
        aws_retry() do
            resp = SQS.send_message_batch(entries, ctx.cfg.queue_url; aws_config=ctx.aws)
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
end

"A received *expand* message: the worker should compute and fan out the run's jobs."
struct ClaimedExpand
    run_id::String
    receipt_handle::String
end

"""
    claim_job(ctx; wait=20) -> Union{ClaimedJob,Nothing}

Long-poll the queue for one job and transition it to `running`. Returns `nothing` if
the queue was empty or the received job turned out to be already finished (its stray
duplicate message is deleted).
"""
function claim_job(ctx::FarmCtx; wait::Int=20)
    resp = SQS.receive_message(ctx.cfg.queue_url,
        Dict("WaitTimeSeconds" => wait, "MaxNumberOfMessages" => 1,
             "VisibilityTimeout" => VISIBILITY_TIMEOUT,
             "AttributeNames" => ["ApproximateReceiveCount"]);
        aws_config=ctx.aws)
    messages = get(resp, "Messages", nothing)
    (messages === nothing || isempty(messages)) && return nothing
    message = only(messages)
    receipt = message["ReceiptHandle"]
    body = JSON.parse(message["Body"])
    get(body, "expand", false) == true && return ClaimedExpand(body["run_id"], receipt)
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
            SQS.delete_message(ctx.cfg.queue_url, receipt; aws_config=ctx.aws)
            return nothing
        end
        rethrow()
    end
    return ClaimedJob(job, receipt, receive_count)
end

worker_identity() = string(get(ENV, "USER", "unknown"), "@", gethostname())

"Extend the message visibility while the job is still being evaluated."
heartbeat(ctx::FarmCtx, claimed::Union{ClaimedJob,ClaimedExpand};
          extend::Int=VISIBILITY_TIMEOUT) =
    SQS.change_message_visibility(ctx.cfg.queue_url, claimed.receipt_handle, extend;
                                  aws_config=ctx.aws)

"Give up on a claimed job without recording a result; it will be redelivered."
function release_job(ctx::FarmCtx, claimed::Union{ClaimedJob,ClaimedExpand}; delay::Int=60)
    try
        SQS.change_message_visibility(ctx.cfg.queue_url, claimed.receipt_handle, delay;
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

    SQS.delete_message(ctx.cfg.queue_url, claimed.receipt_handle; aws_config=ctx.aws)
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
