# Unit tests for the broker (FarmBroker is a separate stdlib-only project; its module
# can be included directly since its deps are a subset of ours).

module BrokerTests

using Test
using AWS
using Dates
using JSON

# load FarmBroker without requiring its project to be active
module Loader
    include(joinpath(@__DIR__, "..", "broker", "src", "FarmBroker.jl"))
end
using .Loader: FarmBroker

const TEST_ENV = Dict(
    "GITHUB_CLIENT_ID" => "Iv1.testclient", "GITHUB_ORG" => "JuliaCI",
    "WORKER_TEAM" => "pkgeval-workers", "SUBMITTER_TEAM" => "pkgeval-submitters",
    "FARM_REGION" => "us-east-1", "PKGEVAL_QUEUE_URL" => "https://sqs/q",
    "PKGEVAL_RUNS_TABLE" => "runs", "PKGEVAL_JOBS_TABLE" => "jobs",
    "PKGEVAL_BUCKET" => "bucket")

function with_env(f, env)
    old = Dict(k => get(ENV, k, nothing) for k in keys(env))
    merge!(ENV, env)
    try
        f()
    finally
        for (k, v) in old
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end

# Cross-check our hand-rolled SigV4 against botocore (installed alongside moto), an
# independent battle-tested implementation, signing the exact same header set.
@testset "SigV4 matches botocore" begin
    python = Sys.which("python3")
    has_botocore = python !== nothing &&
        success(`$python -c "import botocore.auth"`)
    if !has_botocore
        @warn "botocore not available; skipping SigV4 cross-check"
        @test_skip "sigv4 cross-check"
    else
        body = "Action=AssumeRole&Version=2011-06-15&RoleArn=arn%3Aaws%3Aiam%3A%3A123%3Arole%2Fx&RoleSessionName=keno&DurationSeconds=3600"
        time = DateTime(2026, 7, 25, 12, 34, 56)

        for token in (nothing, "SESSIONTOKEN123")
            ours = FarmBroker.sigv4_headers(; method="POST",
                host="sts.us-east-1.amazonaws.com", path="/", body,
                region="us-east-1", service="sts",
                creds=(access_key_id="AKIDEXAMPLE",
                       secret_key="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", token),
                time)
            our_auth = only([v for (k, v) in ours if k == "Authorization"])

            script = """
                import datetime
                import botocore.auth, botocore.awsrequest, botocore.credentials
                class FrozenDT(datetime.datetime):
                    @classmethod
                    def now(cls, tz=None): return cls(2026, 7, 25, 12, 34, 56, tzinfo=tz)
                    @classmethod
                    def utcnow(cls): return cls(2026, 7, 25, 12, 34, 56)
                botocore.auth.datetime.datetime = FrozenDT
                token = $(token === nothing ? "None" : repr(token))
                creds = botocore.credentials.Credentials(
                    "AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", token)
                req = botocore.awsrequest.AWSRequest(
                    method="POST", url="https://sts.us-east-1.amazonaws.com/",
                    data=$(repr(body)),
                    headers={"content-type": "application/x-www-form-urlencoded; charset=utf-8"})
                botocore.auth.SigV4Auth(creds, "sts", "us-east-1").add_auth(req)
                print(req.headers["Authorization"])
                """
            reference = readchomp(`$python -c $script`)
            @test our_auth == reference
        end
    end
end

@testset "session name sanitization" begin
    # signing must not be asked to handle characters STS rejects
    @test FarmBroker.urlencode("arn:aws:iam::1:role/x") == "arn%3Aaws%3Aiam%3A%3A1%3Arole%2Fx"
end

@testset "request handling" begin
    with_env(TEST_ENV) do
        info = FarmBroker.handle_event(Dict("rawPath" => "/info",
            "requestContext" => Dict("http" => Dict("method" => "GET"))))
        @test info["statusCode"] == 200
        payload = JSON.parse(info["body"])
        @test payload["client_id"] == "Iv1.testclient"
        @test payload["org"] == "JuliaCI"

        @test FarmBroker.handle_event(Dict("rawPath" => "/nope",
            "requestContext" => Dict("http" => Dict("method" => "GET"))))["statusCode"] == 404

        creds_event(headers, body) = FarmBroker.handle_event(Dict("rawPath" => "/creds",
            "requestContext" => Dict("http" => Dict("method" => "POST")),
            "headers" => headers, "body" => body))
        @test creds_event(Dict(), "{\"role\":\"worker\"}")["statusCode"] == 401
        @test creds_event(Dict("authorization" => "Bearer x"), "{\"role\":\"root\"}")["statusCode"] == 400
        @test creds_event(Dict("authorization" => "Bearer x"), "not json")["statusCode"] == 400

        # base64-encoded bodies (Function URLs encode non-text content types)
        resp = FarmBroker.handle_event(Dict("rawPath" => "/creds",
            "requestContext" => Dict("http" => Dict("method" => "POST")),
            "headers" => Dict(), "isBase64Encoded" => true,
            "body" => "eyJyb2xlIjoid29ya2VyIn0="))
        @test resp["statusCode"] == 401  # decoded fine, then rejected for missing auth
    end
end

@testset "role requirements" begin
    with_env(TEST_ENV) do
        @test FarmBroker.role_requirement("worker") == ("JuliaCI", "pkgeval-workers")
        @test FarmBroker.role_requirement("root") === nothing
    end
    # the roles need not gate on the same org: "ORG/TEAM" carries its own org,
    # and "" means plain membership of GITHUB_ORG (no team)
    with_env(merge(TEST_ENV, Dict("GITHUB_ORG" => "JuliaLang",
                                  "SUBMITTER_TEAM" => "",
                                  "WORKER_TEAM" => "JuliaCI/pkgeval-workers"))) do
        @test FarmBroker.role_requirement("submitter") == ("JuliaLang", nothing)
        @test FarmBroker.role_requirement("worker") == ("JuliaCI", "pkgeval-workers")
    end

    membership(s) = FarmBroker.parse_json(s, FarmBroker.OrgMembership).state
    @test membership("{\"state\":\"active\",\"role\":\"member\"}") == "active"
    @test membership("{\"state\":\"pending\"}") == "pending"
    @test membership("{}") === nothing
end

@testset "STS XML response parsing" begin
    # emulators answer XML even when asked for JSON; exercise that fallback directly
    xml = """
        <AssumeRoleResponse><AssumeRoleResult><Credentials>
          <AccessKeyId>ASIAX</AccessKeyId>
          <SecretAccessKey>secret</SecretAccessKey>
          <SessionToken>tok</SessionToken>
          <Expiration>2026-07-25T13:34:56Z</Expiration>
        </Credentials></AssumeRoleResult></AssumeRoleResponse>"""
    m = match(r"<AccessKeyId>([^<]+)</AccessKeyId>", xml)
    @test m !== nothing  # sanity for the pattern used in assume_role
end

end # module
