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
        @test run["status"] == "expanding"  # all runs start expanding; a worker fans out
        @test run["total_jobs"] == 0
        @test run["completed_jobs"] == 0
        @test length(run["configs"]) == 2
        @test run["packages"] == packages
        @test isempty(PEF.run_jobs(ctx, run_id))
        @test_throws Exception PEF.create_run(ctx, PEF.RunSpec(configs, packages, Dict{String,Any}());
                                              submitter="tester", run_id)  # ids are unique

        # worker-side fan-out of the stored package list
        claimed = PEF.claim_job(ctx; wait=1)
        @test claimed isa PEF.ClaimedExpand
        @test claimed.run_id == run_id
        @test PEF.expand_run(ctx, run_id, String.(run["packages"])) == 6
        SQS.delete_message(queue_url, claimed.receipt_handle; aws_config=aws)

        run = PEF.get_run(ctx, run_id)
        @test run["status"] == "active"
        @test run["total_jobs"] == 6
        jobs = PEF.run_jobs(ctx, run_id)
        @test length(jobs) == 6
        @test all(j -> j["status"] == "pending", jobs)
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

        # create-only uploads: conditional re-put of an existing log is rejected
        # and the original content survives (first write wins)
        overwrite_err = try
            S3.put_object(cfg.bucket, PEF.log_key(RUN_ID, "primary", "JSON"),
                Dict("body" => "forged",
                     "headers" => Dict("If-None-Match" => "*")); aws_config=aws)
            nothing
        catch err
            err
        end
        @test PEF.is_precondition_failed(overwrite_err)
        @test PEF.job_log(ctx, job) == "log of JSON on primary"

        # report generation runs through FarmBot (the stdlib-only bot Lambda code)
        lite = PEF.FarmLite.LiteCtx(; region="us-east-1",
            creds=PEF.FarmLite.AwsCreds("testing", "testing", nothing),
            queue_url, runs_table=cfg.runs_table, jobs_table=cfg.jobs_table,
            bucket=cfg.bucket, endpoint)
        report = PEF.FarmBot.generate_report(lite, RUN_ID)
        @test occursin("JSON", report.markdown)
        @test occursin("failed on primary but not on against", report.markdown)
        @test occursin("Packages that failed on both", report.markdown)  # Crayons
        @test occursin("package has test failures", report.markdown)  # stored reason_message
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
        expand_claim = PEF.claim_job(ctx; wait=1)
        @test expand_claim isa PEF.ClaimedExpand
        PEF.expand_run(ctx, run_id, ["Broken"])
        SQS.delete_message(queue_url, expand_claim.receipt_handle; aws_config=aws)
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

    @testset "expand jobs" begin
        # empty package list => run starts in `expanding` with a single expand message
        run_id = PEF.create_run(ctx, PEF.RunSpec(configs, String[], Dict{String,Any}());
                                submitter="tester")
        run = PEF.get_run(ctx, run_id)
        @test run["status"] == "expanding"
        @test run["total_jobs"] == 0
        @test isempty(PEF.run_jobs(ctx, run_id))

        claimed = PEF.claim_job(ctx; wait=1)
        @test claimed isa PEF.ClaimedExpand
        @test claimed.run_id == run_id
        PEF.heartbeat(ctx, claimed)  # expansion can be slow (may build Julia)

        # what a worker does after computing the package set
        njobs = PEF.expand_run(ctx, run_id, ["Example", "JSON"])
        @test njobs == 4
        SQS.delete_message(queue_url, claimed.receipt_handle; aws_config=aws)

        run = PEF.get_run(ctx, run_id)
        @test run["status"] == "active"
        @test run["total_jobs"] == 4
        @test length(PEF.run_jobs(ctx, run_id)) == 4

        # a duplicate expand message after the flip only re-enqueues, never resets
        first_claim = PEF.claim_job(ctx; wait=1)
        @test first_claim isa PEF.ClaimedJob
        njobs = PEF.expand_run(ctx, run_id, ["Example", "JSON"])  # redelivery scenario
        @test njobs == 4
        job_item = only(filter(j -> j["job_key"] == PEF.job_key(first_claim.job),
                               PEF.run_jobs(ctx, run_id)))
        @test job_item["status"] == "running"  # not reset back to pending

        # drain: claim everything (incl. duplicates) and finish the run
        PEF.record_result(ctx, first_claim, PEF.JobResult(; status="test", duration=1.0))
        for _ in 1:20  # claim_job also returns nothing for swallowed duplicates
            PEF.get_run(ctx, run_id)["status"] == "done" && break
            c = PEF.claim_job(ctx; wait=1)
            c isa PEF.ClaimedJob || continue
            PEF.record_result(ctx, c, PEF.JobResult(; status="test", duration=1.0))
        end
        run = PEF.get_run(ctx, run_id)
        @test run["status"] == "done"
        @test run["completed_jobs"] == 4
    end

    @testset "bot end-to-end (stub GitHub)" begin
        import HTTP as TestHTTP

        posted = String[]  # comment bodies the bot posts
        gh_base = Ref("")
        notifications = Ref("[]")

        router = TestHTTP.Router()
        TestHTTP.register!(router, "GET", "/notifications",
            req -> TestHTTP.Response(200, notifications[]))
        TestHTTP.register!(router, "PATCH", "/notifications/threads/*",
            req -> TestHTTP.Response(205))
        TestHTTP.register!(router, "GET", "/repos/JuliaLang/julia/issues/comments/1",
            req -> TestHTTP.Response(200, JSON.json(Dict(
                "id" => 987654,
                "body" => "@nanosoldier2 runtests([\"Example\"])",
                "user" => Dict("login" => "keno")))))
        # same command comment as the webhook test delivers (id 555111), for the
        # webhook+poll overlap check
        TestHTTP.register!(router, "GET", "/repos/JuliaLang/julia/issues/comments/2",
            req -> TestHTTP.Response(200, JSON.json(Dict(
                "id" => 555111,
                "body" => "@nanosoldier2 runtests([\"Example\"])",
                "user" => Dict("login" => "keno")))))
        TestHTTP.register!(router, "GET", "/repos/JuliaLang/julia/issues/12345",
            req -> TestHTTP.Response(200, JSON.json(Dict(
                "number" => 12345,
                "repository_url" => "$(gh_base[])/repos/JuliaLang/julia",
                "pull_request" => Dict("url" => "$(gh_base[])/repos/JuliaLang/julia/pulls/12345")))))
        TestHTTP.register!(router, "GET", "/repos/JuliaLang/julia/pulls/12345",
            req -> TestHTTP.Response(200, JSON.json(Dict(
                "head" => Dict("sha" => "abcdef123456"),
                "base" => Dict("ref" => "master")))))
        # author authorization: keno is an active submitter, rando is nobody
        TestHTTP.register!(router, "GET",
            "/orgs/KenoAIStaging/teams/pkgeval-submitters/memberships/keno",
            req -> TestHTTP.Response(200, JSON.json(Dict("state" => "active"))))
        TestHTTP.register!(router, "GET",
            "/orgs/KenoAIStaging/teams/pkgeval-submitters/memberships/rando",
            req -> TestHTTP.Response(404, "{}"))
        TestHTTP.register!(router, "GET", "/orgs/KenoAIStaging/members/keno",
            req -> TestHTTP.Response(204))
        TestHTTP.register!(router, "GET", "/orgs/KenoAIStaging/members/rando",
            req -> TestHTTP.Response(404, "{}"))
        ENV["GITHUB_ORG"] = "KenoAIStaging"
        ENV["SUBMITTER_TEAM"] = "pkgeval-submitters"
        TestHTTP.register!(router, "POST", "/repos/JuliaLang/julia/issues/12345/comments",
            req -> begin
                push!(posted, JSON.parse(String(req.body))["body"])
                TestHTTP.Response(201, "{}")
            end)
        gh_port = rand(30001:40000)
        server = TestHTTP.serve!(router, "127.0.0.1", gh_port)
        gh_base[] = "http://127.0.0.1:$gh_port"
        SQS.purge_queue(queue_url; aws_config=aws)  # drop strays from earlier testsets
        gh = PEF.FarmLite.GitHubCtx("bot-token", gh_base[])

        lite = PEF.FarmLite.LiteCtx(; region="us-east-1",
            creds=PEF.FarmLite.AwsCreds("testing", "testing", nothing),
            queue_url, runs_table=cfg.runs_table, jobs_table=cfg.jobs_table,
            bucket=cfg.bucket, endpoint)

        try
            # 1. a mention arrives -> bot submits a run and acks
            notifications[] = JSON.json([Dict(
                "id" => "42", "reason" => "mention",
                "subject" => Dict("type" => "PullRequest",
                    "url" => "$(gh_base[])/repos/JuliaLang/julia/issues/12345",
                    "latest_comment_url" => "$(gh_base[])/repos/JuliaLang/julia/issues/comments/1"))])
            PEF.FarmBot.handle_invocation(lite, gh)
            @test length(posted) == 1
            @test occursin("has been submitted as run", posted[1])
            @test occursin("JuliaLang/julia#abcdef123456", posted[1])
            run_id = match(r"run `([^`]+)`", posted[1]).captures[1]

            run = PEF.get_run(ctx, run_id)
            @test run["status"] == "expanding"
            @test run["packages"] == ["Example"]
            @test run["context"]["repo"] == "JuliaLang/julia"
            @test run["submitter"] == "keno via @nanosoldier2"
            @test run["configs"][1]["name"] == "primary"
            @test run["configs"][1]["julia"] == "JuliaLang/julia#abcdef123456"
            @test run["configs"][2]["julia"] == "JuliaLang/julia#master"
            # the config json round-trips into a PkgEval Configuration
            config = PEF.config_from_dict(run["configs"][1])
            @test config.buildflags == ["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"]

            # 2. a worker picks it up, expands and completes it
            notifications[] = "[]"
            expand_claim = PEF.claim_job(ctx; wait=1)
            @test expand_claim isa PEF.ClaimedExpand
            PEF.expand_run(ctx, run_id, ["Example"])
            SQS.delete_message(queue_url, expand_claim.receipt_handle; aws_config=aws)
            for _ in 1:20  # claim_job also returns nothing for swallowed duplicates
                PEF.get_run(ctx, run_id)["status"] == "done" && break
                c = PEF.claim_job(ctx; wait=1)
                c isa PEF.ClaimedJob || continue
                PEF.record_result(ctx, c, PEF.JobResult(; status="test", version="1.0.0",
                                                        duration=1.0, log="ok"))
            end
            @test PEF.get_run(ctx, run_id)["status"] == "done"

            # 3. next poll posts the report
            PEF.FarmBot.handle_invocation(lite, gh)
            @test length(posted) == 2
            @test occursin("@keno: run `$run_id` finished", posted[2])
            @test occursin("no new package failures", posted[2])
            @test occursin("report.md", posted[2])

            # 4. and does not double-post
            PEF.FarmBot.handle_invocation(lite, gh)
            @test length(posted) == 2

            # 5. webhook path: an issue_comment delivery submits a run with a
            #    single GitHub call (no notifications involved)
            secret = "hooksecret"
            payload = JSON.json(Dict(
                "action" => "created",
                "comment" => Dict("id" => 555111,
                                  "body" => "@nanosoldier2 runtests([\"Example\"])",
                                  "user" => Dict("login" => "keno")),
                "issue" => Dict("number" => 12345,
                                "pull_request" => Dict("url" => "$(gh_base[])/repos/JuliaLang/julia/pulls/12345")),
                "repository" => Dict("full_name" => "JuliaLang/julia")))
            sign(body) = "sha256=" * bytes2hex(PEF.FarmLite.hmac(Vector{UInt8}(secret), body))
            webhook_event(body, sig) = JSON.json(Dict(
                "requestContext" => Dict("http" => Dict("method" => "POST")),
                "rawPath" => "/",
                "headers" => Dict("x-hub-signature-256" => sig,
                                  "x-github-event" => "issue_comment"),
                "body" => body, "isBase64Encoded" => false))
            with_env(Dict("GITHUB_WEBHOOK_SECRET" => secret)) do
                # bad signature is rejected without side effects
                resp = JSON.parse(PEF.FarmBot.handle_event(webhook_event(payload, sign("evil")), lite, gh))
                @test resp["statusCode"] == 401
                @test length(posted) == 2

                resp = JSON.parse(PEF.FarmBot.handle_event(webhook_event(payload, sign(payload)), lite, gh))
                @test resp["statusCode"] == 200
            end
            @test length(posted) == 3
            @test occursin("has been submitted as run", posted[3])
            webhook_run_id = match(r"run `([^`]+)`", posted[3]).captures[1]
            @test webhook_run_id == "gh-555111"  # deterministic, comment-derived

            # 5a. duplicate deliveries collapse into the one run: a webhook
            # redelivery and the fallback poll rediscovering the same comment
            # both submit nothing and post nothing
            with_env(Dict("GITHUB_WEBHOOK_SECRET" => secret)) do
                resp = JSON.parse(PEF.FarmBot.handle_event(
                    webhook_event(payload, sign(payload)), lite, gh))
                @test resp["statusCode"] == 200
            end
            notifications[] = JSON.json([Dict(
                "id" => "43", "reason" => "mention",
                "subject" => Dict("type" => "PullRequest",
                    "url" => "$(gh_base[])/repos/JuliaLang/julia/issues/12345",
                    "latest_comment_url" => "$(gh_base[])/repos/JuliaLang/julia/issues/comments/2"))])
            PEF.FarmBot.handle_invocation(lite, gh)
            notifications[] = "[]"
            @test length(posted) == 3      # no extra ack comments
            run = PEF.get_run(ctx, "gh-555111")
            @test run["status"] == "expanding"  # still exactly one run, untouched

            # 5b. an unauthorized author gets a refusal and no run
            intruder = replace(payload, "\"login\":\"keno\"" => "\"login\":\"rando\"")
            with_env(Dict("GITHUB_WEBHOOK_SECRET" => secret)) do
                resp = JSON.parse(PEF.FarmBot.handle_event(
                    webhook_event(intruder, sign(intruder)), lite, gh))
                @test resp["statusCode"] == 200
            end
            @test length(posted) == 4
            @test occursin("only members of the KenoAIStaging/pkgeval-submitters team", posted[4])
            posted_refusal = pop!(posted)  # keep later indices stable

            # both authorization modes, checked directly
            @test PEF.FarmBot.authorized_submitter(gh, "keno")
            @test !PEF.FarmBot.authorized_submitter(gh, "rando")
            with_env(Dict("SUBMITTER_TEAM" => "")) do  # org-membership mode
                @test PEF.FarmBot.authorized_submitter(gh, "keno")
                @test !PEF.FarmBot.authorized_submitter(gh, "rando")
            end
            run = PEF.get_run(ctx, webhook_run_id)
            @test run["packages"] == ["Example"]
            @test run["submitter"] == "keno via @nanosoldier2"

            # 6. stream path: a run flipping to done triggers the report directly
            expand_claim = PEF.claim_job(ctx; wait=1)
            @test expand_claim isa PEF.ClaimedExpand
            PEF.expand_run(ctx, webhook_run_id, ["Example"])
            SQS.delete_message(queue_url, expand_claim.receipt_handle; aws_config=aws)
            for _ in 1:20
                PEF.get_run(ctx, webhook_run_id)["status"] == "done" && break
                c = PEF.claim_job(ctx; wait=1)
                c isa PEF.ClaimedJob || continue
                PEF.record_result(ctx, c, PEF.JobResult(; status="test", duration=1.0))
            end
            @test PEF.get_run(ctx, webhook_run_id)["status"] == "done"

            run_item = PEF.FarmBot.get_run(lite, String(webhook_run_id))
            stream_event = JSON.json(Dict("Records" => [Dict(
                "eventName" => "MODIFY",
                "dynamodb" => Dict("NewImage" => JSON.parse(PEF.FarmLite.json_item(run_item))))]))
            @test JSON.parse(PEF.FarmBot.handle_event(stream_event, lite, gh))["ok"] == true
            @test length(posted) == 4
            @test occursin("@keno: run `$webhook_run_id` finished", posted[4])

            # duplicate stream delivery does not double-post
            @test JSON.parse(PEF.FarmBot.handle_event(stream_event, lite, gh))["ok"] == true
            @test length(posted) == 4

            # 7. an unrecognized event falls back to the scheduled poll
            notifications[] = "[]"
            @test JSON.parse(PEF.FarmBot.handle_event("{}", lite, gh))["ok"] == true
            @test length(posted) == 4
        finally
            close(server)
        end
    end

    @testset "broker STS against moto" begin
        with_env(Dict("AWS_ACCESS_KEY_ID" => "testing", "AWS_SECRET_ACCESS_KEY" => "testing",
                      "FARM_REGION" => "us-east-1", "STS_ENDPOINT" => endpoint)) do
            creds = FarmBroker.assume_role("arn:aws:iam::123456789012:role/pkgeval-worker",
                                           "keno"; duration=3600)
            @test !isempty(creds.access_key_id)
            @test !isempty(creds.session_token)
            # expiration parses and is in the future
            exp = PEF.parse_expiration(creds.expiration)
            @test exp > Dates.now(UTC)
        end
    end
finally
    kill(proc)
end

end # moto_available

end # module
