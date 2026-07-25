# Integration tests against a local moto server (pip install 'moto[server]'),
# exercising the full run/job lifecycle plus the broker's STS call.

module MotoTests

using Test
using AWS
using Dates
using JSON
using PkgEvalFarm
using Sockets
import PkgEval

using ..BrokerTests: FarmBroker, with_env

const PEF = PkgEvalFarm

using AWS: @service
@service Dynamodb
@service SQS
@service S3

# AWS config pointing every service at the moto endpoint
struct MotoConfig <: AWS.AbstractAWSConfig
    endpoint::String
    region::String
    creds::AWS.AWSCredentials
end
AWS.region(c::MotoConfig) = c.region
AWS.credentials(c::MotoConfig) = c.creds
AWS.generate_service_url(c::MotoConfig, service::String, resource::String) =
    string(c.endpoint, resource)

function start_moto()
    port = rand(20000:30000)
    proc = run(pipeline(`moto_server -p $port`; stdout=devnull, stderr=devnull); wait=false)
    for _ in 1:100
        try
            close(Sockets.connect("127.0.0.1", port))
            return proc, port
        catch
            sleep(0.1)
        end
        process_exited(proc) && break
    end
    error("moto_server did not come up (is 'moto[server]' installed?)")
end

moto_available = Sys.which("moto_server") !== nothing
if !moto_available
    @warn "moto_server not found; skipping integration tests"
    @test_skip "moto integration"
else

proc, port = start_moto()
endpoint = "http://127.0.0.1:$port"
aws = MotoConfig(endpoint, "us-east-1", AWS.AWSCredentials("testing", "testing"))

try
    # provision the same resources terraform would
    for (table, keys) in ["pkgeval-runs" => [("run_id", "HASH")],
                          "pkgeval-jobs" => [("run_id", "HASH"), ("job_key", "RANGE")]]
        Dynamodb.create_table(
            [Dict("AttributeName" => k, "AttributeType" => "S") for (k, _) in keys],
            [Dict("AttributeName" => k, "KeyType" => t) for (k, t) in keys],
            table, Dict("BillingMode" => "PAY_PER_REQUEST"); aws_config=aws)
    end
    queue_url = SQS.create_queue("pkgeval-jobs"; aws_config=aws)["QueueUrl"]
    S3.create_bucket("pkgeval-results"; aws_config=aws)

    cfg = FarmConfig(; region="us-east-1", queue_url, runs_table="pkgeval-runs",
                     jobs_table="pkgeval-jobs", bucket="pkgeval-results")
    ctx = FarmCtx(cfg, aws)

    configs = [PkgEval.Configuration(; name="primary", julia="JuliaLang/julia#abc123"),
               PkgEval.Configuration(; name="against", julia="v1.12.0")]
    packages = ["Example", "Crayons", "JSON"]

    @testset "create_run" begin
        run_id = PEF.create_run(ctx, PEF.RunSpec(configs, packages, Dict{String,Any}());
                                submitter="tester")
        global RUN_ID = run_id
        run = PEF.get_run(ctx, run_id)
        @test run["status"] == "active"
        @test run["total_jobs"] == 6
        @test run["completed_jobs"] == 0
        @test length(run["configs"]) == 2
        jobs = PEF.run_jobs(ctx, run_id)
        @test length(jobs) == 6
        @test all(j -> j["status"] == "pending", jobs)
        @test_throws Exception PEF.create_run(ctx, PEF.RunSpec(configs, packages, Dict{String,Any}());
                                              submitter="tester", run_id)  # ids are unique
    end

    @testset "claim/heartbeat/complete lifecycle" begin
        seen = Set{Tuple{String,String}}()
        for i in 1:6
            claimed = PEF.claim_job(ctx; wait=1)
            @test claimed !== nothing
            push!(seen, (claimed.job.config, claimed.job.package))
            @test claimed.attempts == 1

            job_item = only(filter(j -> j["job_key"] == PEF.job_key(claimed.job),
                                   PEF.run_jobs(ctx, RUN_ID)))
            @test job_item["status"] == "running"
            @test job_item["attempts"] == 1

            PEF.heartbeat(ctx, claimed)  # must not throw

            # fabricate results: JSON fails on primary only; Crayons fails everywhere
            status = (claimed.job.package == "JSON" && claimed.job.config == "primary") ? "fail" :
                     claimed.job.package == "Crayons" ? "crash" : "test"
            result = PEF.JobResult(; status,
                reason=status == "fail" ? "test_failures" :
                       status == "crash" ? "segfault" : nothing,
                version="1.2.3", duration=42.0,
                log="log of $(claimed.job.package) on $(claimed.job.config)")
            PEF.record_result(ctx, claimed, result)
        end
        @test length(seen) == 6

        run = PEF.get_run(ctx, RUN_ID)
        @test run["completed_jobs"] == 6
        @test run["status"] == "done"

        # queue is drained
        @test PEF.claim_job(ctx; wait=0) === nothing
    end

    @testset "duplicate delivery is harmless" begin
        # simulate SQS at-least-once: re-enqueue an already-finished job
        PEF.enqueue_jobs(ctx, [PEF.JobRef(RUN_ID, "primary", "Example")])
        @test PEF.claim_job(ctx; wait=1) === nothing  # detected as done, message deleted
        @test PEF.claim_job(ctx; wait=0) === nothing  # and not redelivered
        run = PEF.get_run(ctx, RUN_ID)
        @test run["completed_jobs"] == 6  # counter untouched
    end

    @testset "logs and report" begin
        jobs = PEF.run_jobs(ctx, RUN_ID)
        job = only(filter(j -> j["job_key"] == "primary#JSON", jobs))
        @test PEF.job_log(ctx, job) == "log of JSON on primary"

        report = PEF.generate_report(ctx, RUN_ID)
        @test occursin("JSON", report.markdown)
        @test occursin("failed on primary but not on against", report.markdown)
        @test occursin("Packages that failed on both", report.markdown)  # Crayons
        @test !occursin("Example", split(report.markdown, "failed on both")[1]) ||
              occursin("now pass", report.markdown)
        @test occursin("possible new issues: 1 package", report.summary)

        # uploaded artifacts
        fetch_raw(key) = String(copy(S3.get_object(cfg.bucket, key,
            Dict("return_raw" => true); aws_config=aws)))
        @test fetch_raw(PEF.report_key(RUN_ID, "report.md")) == report.markdown
        db = JSON.parse(fetch_raw(PEF.report_key(RUN_ID, "db.json")))
        @test length(db["jobs"]) == 6
    end

    @testset "worker error handling" begin
        # a job whose evaluation throws gets released, then errored out at attempt >= 3
        run_id = PEF.create_run(ctx, PEF.RunSpec(configs[1:1], ["Broken"], Dict{String,Any}());
                                submitter="tester")
        for attempt in 1:3
            claimed = PEF.claim_job(ctx; wait=1)
            @test claimed !== nothing
            @test claimed.job.package == "Broken"
            if attempt < 3
                PEF.release_job(ctx, claimed; delay=0)
            else
                @test claimed.attempts == 3
                PEF.record_result(ctx, claimed, PEF.JobResult(; status="error",
                    reason="worker_exception", log="boom"))
            end
        end
        run = PEF.get_run(ctx, run_id)
        @test run["status"] == "done"
        job = only(PEF.run_jobs(ctx, run_id))
        @test job["status"] == "error"
        @test job["attempts"] == 3
    end

    @testset "broker STS against moto" begin
        with_env(Dict("AWS_ACCESS_KEY_ID" => "testing", "AWS_SECRET_ACCESS_KEY" => "testing",
                      "FARM_REGION" => "us-east-1", "STS_ENDPOINT" => endpoint)) do
            creds = FarmBroker.assume_role("arn:aws:iam::123456789012:role/pkgeval-worker",
                                           "keno"; duration=3600)
            @test !isempty(creds["access_key_id"])
            @test !isempty(creds["session_token"])
            # expiration parses and is in the future
            exp = PEF.parse_expiration(creds["expiration"])
            @test exp > Dates.now(UTC)
        end
    end
finally
    kill(proc)
end

end # moto_available

end # module
