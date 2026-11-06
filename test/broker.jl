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


@testset "web submission: pure parts" begin
    FB = FarmBroker
    @test FB.parse_query("a=b%20c&d=e+f&g&=x") == ["a" => "b c", "d" => "e f", "g" => "", "" => "x"]
    @test FB.urldecode("%2") == "%2"  # truncated escapes stay literal
    @test FB.urldecode("%zz") == "%zz"

    q(s) = FB.parse_query(s)
    spec, err = FB.parse_spec(q("primary=JuliaLang/julia%23master&against=1.12.0&packages=Example,JSON.jl+Example&request=abcdefgh"))
    @test err == ""
    @test spec.primary == "JuliaLang/julia#master"
    @test spec.against == "v1.12.0"   # the spelling baseline reuse recognizes
    @test occursin(r"^v\d+\.\d+\.\d+$", spec.against)
    @test spec.packages == ["Example", "JSON"]
    @test !spec.assertions && !spec.fresh_baseline
    @test FB.run_id(spec) == "web-abcdefgh"
    # the canonical query is what gets signed; it must round-trip
    again, _ = FB.parse_spec(q(FB.spec_query(spec)))
    @test FB.spec_query(again) == FB.spec_query(spec)
    @test FB.link_digest(again) == FB.link_digest(spec)
    @test FB.configs_json(spec) ==
        "[{\"name\":\"primary\",\"julia\":\"JuliaLang/julia#master\",\"buildflags\":[]}," *
        "{\"name\":\"against\",\"julia\":\"v1.12.0\",\"buildflags\":[]}]"

    # with assertions a version means its release tag (only commits have assert builds)
    spec, _ = FB.parse_spec(q("primary=1.13.0-rc1&assertions=true&request=abcdefgh"))
    @test spec.primary == "JuliaLang/julia#v1.13.0-rc1"
    @test spec.assertions
    @test occursin("LLVM_ASSERTIONS=1", FB.configs_json(spec))

    bad(s) = (r = FB.parse_spec(q(s)); r[1] === nothing ? r[2] : nothing)
    @test occursin("required", bad("request=abcdefgh"))
    @test occursin("only once", bad("primary=nightly&primary=1.12.0&request=abcdefgh"))
    @test occursin("unknown parameter `context`", bad("primary=nightly&context=x&request=abcdefgh"))
    @test occursin("no assertions build", bad("primary=nightly&assertions=1&request=abcdefgh"))
    @test occursin("only JuliaLang/julia", bad("primary=Evil/julia%23main&request=abcdefgh"))
    @test occursin("not a Julia spec", bad("primary=latest&request=abcdefgh"))
    @test occursin("not a valid git ref", bad("primary=JuliaLang/julia%23..%2Fx%3B&request=abcdefgh"))
    @test occursin("not a package name", bad("primary=nightly&packages=Foo,<script>&request=abcdefgh"))
    @test occursin("true or false", bad("primary=nightly&assertions=maybe&request=abcdefgh"))
    @test occursin("missing request", bad("primary=nightly"))
    @test occursin("request must be", bad("primary=nightly&request=short"))
    @test occursin("UTF-8", bad("primary=nightly&request=abcdefgh&packages=%ff"))
    # a trailing newline or look-alike digits never pass
    @test occursin("request must be", bad("primary=nightly&request=abcdefgh%0A"))
    @test occursin("not a Julia spec", bad("primary=%EF%BC%91.%EF%BC%91%EF%BC%92.%EF%BC%90&request=abcdefgh"))
    # pages quote rejected values only when they are short and plain
    prose = bad("primary=Your+session+expired%2C+sign+in+at+evil.example&request=abcdefgh")
    @test occursin("the value given", prose) && !occursin("evil.example", prose)
    @test !occursin("evil", bad("primary=nightly&please+visit+evil.example=1&request=abcdefgh"))
    many = join(["P$i" for i in 1:FB.MAX_PACKAGES+1], ",")
    @test occursin("at most", bad("primary=nightly&packages=$many&request=abcdefgh"))
    generated, _ = FB.parse_spec(q("primary=nightly"); generate_request=true)
    @test occursin(r"^[0-9a-f]{24}$", generated.request)

    key = FB.signing_key("s3cret")
    token = FB.signed(key, "ticket", "login=alice&primary=nightly")
    @test FB.verify_signed(key, "ticket", token) == "login=alice&primary=nightly"
    @test FB.verify_signed(key, "state", token) === nothing          # purposes don't mix
    @test FB.verify_signed(FB.signing_key("other"), "ticket", token) === nothing
    @test FB.verify_signed(key, "ticket", replace(token, "alice" => "bob")) === nothing
    @test FB.verify_signed(key, "ticket", "login=alice") === nothing

    @test FB.html_escape("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;"
    @test FB.base64encode_compat("a") == "YQ=="
    @test FB.base64encode_compat("ab") == "YWI="
    @test FB.base64encode_compat("abc") == "YWJj"
    @test FB.base64encode_compat("Iv:secret") == "SXY6c2VjcmV0"
    @test FB.oauth_error_text("access_denied") == "the authorization was declined on GitHub"
    @test FB.oauth_error_text("Re-authorize at evil.example") == "GitHub sign-in did not complete"

    ev = Dict("cookies" => ["x=1", "pkgeval_submit_ab=1"], "headers" => Dict("cookie" => "y=2; z=3"))
    @test FB.cookie_value(ev, "pkgeval_submit_ab") == "1"
    @test FB.cookie_value(ev, "z") == "3"
    @test FB.cookie_value(ev, "nope") === nothing

    # typed event parsing (what the compiled runtime loop sees)
    typed = FB.parse_json("""{"rawPath":"/submit","rawQueryString":"primary=nightly",
        "cookies":["a=b"],"requestContext":{"http":{"method":"GET"}},"headers":{"host":"h"}}""",
        FB.LambdaEvent)
    @test FB.event_query(typed) == "primary=nightly"
    @test FB.event_cookies(typed) == ["a=b"]
    @test FB.event_header(typed, "host") == "h"
    @test FB.event_header(typed, "x-amz-cf-id") === nothing
end

@testset "web submission: flow (stub GitHub and AWS)" begin
    import HTTP as WebHTTP
    FB = FarmBroker
    sha = "a"^40
    seen = Dict{String,Vector{String}}("revoked" => String[], "session" => String[],
                                       "put" => String[], "send" => String[], "ssm" => String[])
    runs = Dict{String,Any}()  # run_id => item, as PutItem stored it
    ssm_value = Ref("placeholder-set-out-of-band")
    form(req) = Dict(FB.parse_query(String(copy(req.body))))  # String(::Vector) empties it
    header(req, name) = WebHTTP.header(req, name)
    tokens = Dict("good" => "gho_alice", "outsider" => "gho_mallory")
    logins = Dict("gho_alice" => "alice", "gho_mallory" => "mallory")
    bearer(req) = replace(header(req, "Authorization"), r"^Bearer " => "")

    router = WebHTTP.Router()
    WebHTTP.register!(router, "POST", "/login/oauth/access_token", req -> begin
        f = form(req)
        f["client_secret"] == "s3cret" || return WebHTTP.Response(200, "{\"error\":\"incorrect_client_credentials\"}")
        f["redirect_uri"] == "https://farm.example/submit/callback" ||
            return WebHTTP.Response(200, "{\"error\":\"redirect_uri_mismatch\"}")
        haskey(tokens, f["code"]) || return WebHTTP.Response(200, "{\"error\":\"bad_verification_code\"}")
        WebHTTP.Response(200, JSON.json(Dict("access_token" => tokens[f["code"]],
                                             "token_type" => "bearer", "scope" => "read:org,read:user")))
    end)
    WebHTTP.register!(router, "GET", "/user", req -> begin
        t = bearer(req)
        haskey(logins, t) ? WebHTTP.Response(200, JSON.json(Dict("login" => logins[t]))) :
                            WebHTTP.Response(401, "{}")
    end)
    WebHTTP.register!(router, "GET", "/user/memberships/orgs/JuliaLang", req ->
        bearer(req) == "gho_alice" ? WebHTTP.Response(200, "{\"state\":\"active\"}") :
                                     WebHTTP.Response(404, "{}"))
    WebHTTP.register!(router, "GET", "/repos/JuliaLang/julia/commits/*", req -> begin
        ref = split(req.target, '/')[end]
        ref in ("master", "v1.12.0") ? WebHTTP.Response(200, JSON.json(Dict("sha" => sha))) :
                                       WebHTTP.Response(422, "{}")
    end)
    WebHTTP.register!(router, "DELETE", "/applications/Iv1.testclient/token", req -> begin
        header(req, "Authorization") == "Basic " * FB.base64encode_compat("Iv1.testclient:s3cret") ||
            return WebHTTP.Response(401, "{}")
        push!(seen["revoked"], JSON.parse(String(copy(req.body)))["access_token"])
        WebHTTP.Response(204)
    end)
    # STS, DynamoDB, SQS and SSM share the emulated AWS endpoint
    WebHTTP.register!(router, "POST", "/", req -> begin
        target = header(req, "x-amz-target")
        body = String(copy(req.body))
        if isempty(target)  # STS (Query protocol)
            f = Dict(FB.parse_query(body))
            push!(seen["session"], f["RoleSessionName"])
            return WebHTTP.Response(200, """
                <AssumeRoleResponse><AssumeRoleResult><Credentials>
                <AccessKeyId>ASIAWEB</AccessKeyId><SecretAccessKey>s</SecretAccessKey>
                <SessionToken>t</SessionToken><Expiration>2030-01-01T00:00:00Z</Expiration>
                </Credentials></AssumeRoleResult></AssumeRoleResponse>""")
        elseif target == "DynamoDB_20120810.PutItem"
            item = JSON.parse(body)["Item"]
            id = item["run_id"]["S"]
            push!(seen["put"], body)
            haskey(runs, id) && return WebHTTP.Response(400, JSON.json(Dict(
                "__type" => "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",
                "message" => "The conditional request failed")))
            runs[id] = item
            return WebHTTP.Response(200, "{}")
        elseif target == "DynamoDB_20120810.GetItem"
            r = JSON.parse(body)
            r["ConsistentRead"] == true || return WebHTTP.Response(400, "expected a consistent read")
            item = copy(runs[r["Key"]["run_id"]["S"]])
            item["status"] = Dict("S" => "running")
            return WebHTTP.Response(200, JSON.json(Dict("Item" => item)))
        elseif target == "AmazonSQS.SendMessage"
            push!(seen["send"], JSON.parse(body)["MessageBody"])
            return WebHTTP.Response(200, "{\"MessageId\":\"1\"}")
        elseif target == "AmazonSSM.GetParameter"
            push!(seen["ssm"], JSON.parse(body)["Name"])
            return WebHTTP.Response(200, JSON.json(Dict("Parameter" => Dict("Value" => ssm_value[]))))
        end
        WebHTTP.Response(400, "unexpected $target")
    end)
    port, server = let p = 0, srv = nothing
        for attempt in 1:10
            p = rand(30001:40000)
            try
                srv = WebHTTP.serve!(router, "127.0.0.1", p)
                break
            catch err
                attempt == 10 && rethrow()
            end
        end
        p, srv
    end
    stub = "http://127.0.0.1:$port"
    web_env = merge(TEST_ENV, Dict(
        "GITHUB_ORG" => "JuliaLang", "SUBMITTER_TEAM" => "",
        "SUBMITTER_ROLE_ARN" => "arn:aws:iam::1:role/submitter",
        "PUBLIC_URL" => "https://farm.example/", "GITHUB_WEB" => stub, "GITHUB_API" => stub,
        "STS_ENDPOINT" => stub, "FARM_ENDPOINT" => stub,
        "AWS_ACCESS_KEY_ID" => "AKIDBROKER", "AWS_SECRET_ACCESS_KEY" => "secret",
        "GITHUB_CLIENT_SECRET_PARAM" => "/pkgeval/github-client-secret"))
    # what CloudFront forwards: its request id, and the Function URL as Host
    cdn = Dict("x-amz-cf-id" => "cf1", "host" => "abc.lambda-url.us-east-2.on.aws")
    get_event(path, query; cookies=String[], headers=cdn) = Dict("rawPath" => path,
        "rawQueryString" => query, "requestContext" => Dict("http" => Dict("method" => "GET")),
        "headers" => headers, "cookies" => cookies)
    post_event(body; cookies=String[]) = Dict("rawPath" => "/submit",
        "requestContext" => Dict("http" => Dict("method" => "POST")),
        "headers" => merge(cdn, Dict("content-type" => "application/x-www-form-urlencoded")),
        "cookies" => cookies, "body" => body)
    unescape(s) = replace(s, "&quot;" => "\"", "&#39;" => "'", "&lt;" => "<", "&gt;" => ">", "&amp;" => "&")
    ticket_of(html) = unescape(match(r"name=\"ticket\" value=\"([^\"]*)\"", html).captures[1])
    # a browser's cookie jar: name=value pairs, a later Set-Cookie of a name replaces it
    jar = Dict{String,String}()
    function remember!(resp)
        for c in resp["cookies"]
            m = match(r"^([^=;]+)=([^;]*);.*Max-Age=(\d+)", c)
            m.captures[3] == "0" ? delete!(jar, m.captures[1]) : (jar[m.captures[1]] = m.captures[2])
        end
        return resp
    end
    cookies() = ["$k=$v" for (k, v) in jar]
    query_of(location) = Dict(FB.parse_query(split(location, '?'; limit=2)[2]))
    start(query) = remember!(FB.handle_event(get_event("/submit", query; cookies=cookies())))
    callback(code, st; cookies=cookies()) = remember!(FB.handle_event(get_event("/submit/callback",
        "code=$code&state=" * FB.urlencode(st); cookies)))
    review(location; cookies=cookies()) = FB.handle_event(get_event("/submit/review",
        split(location, '?'; limit=2)[2]; cookies))
    post(t; confirm=true, cookies=cookies()) = FB.handle_event(post_event(
        "ticket=" * FB.urlencode(t) * (confirm ? "&confirm=yes" : ""); cookies))
    "Link -> GitHub -> review page; returns (review response, its URL)."
    function through_review(query; code="good")
        s = start(query)
        @assert s["statusCode"] == 302 s["body"]
        cb = callback(code, query_of(s["headers"]["Location"])["state"])
        cb["statusCode"] == 302 || return (cb, "")
        location = cb["headers"]["Location"]
        return (review(location), location)
    end
    reset!() = (FB.CLIENT_SECRET[] = nothing; FB.SECRET_MISS_AT[] = 0)

    try
        reset!()
        # not configured: no secret anywhere
        with_env(merge(TEST_ENV, Dict("PUBLIC_URL" => "https://farm.example"))) do
            r = FB.handle_event(get_event("/submit", "primary=nightly"))
            @test r["statusCode"] == 503
        end

        with_env(web_env) do
            # a placeholder secret means not configured, and is remembered for a while
            @test FB.handle_event(get_event("/submit", "primary=nightly"))["statusCode"] == 503
            @test FB.handle_event(get_event("/submit", "primary=nightly"))["statusCode"] == 503
            @test seen["ssm"] == ["/pkgeval/github-client-secret"]
            ssm_value[] = "s3cret\n"
            FB.SECRET_MISS_AT[] = 0  # the cache has expired

            # a link on the raw Function URL moves to the public host first
            direct = FB.handle_event(get_event("/submit", "primary=nightly&request=req-0009";
                headers=Dict("host" => "abc.lambda-url.us-east-2.on.aws")))
            @test direct["statusCode"] == 302
            @test direct["headers"]["Location"] == "https://farm.example/submit?primary=nightly&request=req-0009"
            @test isempty(direct["cookies"])
            @test length(seen["ssm"]) == 2  # read once more, trimmed, and cached

            s = start("primary=JuliaLang/julia%23master&against=1.12.0&packages=Example&request=req-0001")
            @test s["statusCode"] == 302
            location = s["headers"]["Location"]
            @test startswith(location, stub * "/login/oauth/authorize?client_id=Iv1.testclient&")
            @test occursin("redirect_uri=https%3A%2F%2Ffarm.example%2Fsubmit%2Fcallback", location)
            @test occursin("scope=read%3Aorg%20read%3Auser", location)  # its own token bucket
            cookie = only(s["cookies"])
            @test occursin(r"^pkgeval_submit_[0-9a-f]{32}=1;", cookie)
            @test occursin("HttpOnly", cookie) && occursin("Secure", cookie) && occursin("SameSite=Lax", cookie)
            state = query_of(location)["state"]

            # the sign-in must come back to the browser that started it
            r = callback("good", state; cookies=String[])
            @test r["statusCode"] == 400 && occursin("another browser", r["body"])
            r = callback("good", replace(state, "master" => "evil"))
            @test r["statusCode"] == 400 && occursin("altered", r["body"])
            @test isempty(seen["revoked"])  # neither got as far as a token
            # GitHub's error codes become fixed texts; nothing a link chose is echoed
            r = FB.handle_event(get_event("/submit/callback",
                "error=Re-authorize+at+evil.example&state=x"; cookies=cookies()))
            @test r["statusCode"] == 403 && !occursin("evil", r["body"])

            # a non-member is refused; their token is revoked all the same
            r = callback("outsider", state)
            @test r["statusCode"] == 403
            @test occursin("not a member of the JuliaLang organization", r["body"])
            @test seen["revoked"] == ["gho_mallory"]

            cb = callback("good", state)
            @test cb["statusCode"] == 302  # Post/Redirect/Get: the code is spent once
            @test seen["revoked"] == ["gho_mallory", "gho_alice"]
            @test occursin("Max-Age=$(FB.TICKET_TTL)", only(cb["cookies"]))  # outlives the ticket
            review_location = cb["headers"]["Location"]
            @test startswith(review_location, "https://farm.example/submit/review?t=")
            page = review(review_location)
            @test page["statusCode"] == 200
            html = page["body"]
            @test occursin("Submit this run as @alice", html)
            @test occursin("JuliaLang/julia#$sha", html)          # pinned ...
            @test occursin("(JuliaLang/julia#master)", html)     # ... and what it was
            @test occursin("web-req-0001", html)
            @test occursin("name=\"confirm\" value=\"yes\" required", html)
            @test page["headers"]["X-Frame-Options"] == "DENY"
            @test occursin("frame-ancestors 'none'", page["headers"]["Content-Security-Policy"])
            @test review(review_location)["body"] == html  # reloading is harmless
            @test isempty(seen["put"])  # reviewing submits nothing
            ticket = ticket_of(html)

            # a second link opened meanwhile in the same browser does not break the first
            page2, review2 = through_review("primary=1.12.0&packages=JSON&request=req-0004")
            @test page2["statusCode"] == 200

            r = post(ticket; cookies=String[])
            @test r["statusCode"] == 400 && isempty(seen["put"])
            r = post(ticket; confirm=false)
            @test r["statusCode"] == 400 && occursin("confirmation box", r["body"]) && isempty(seen["put"])
            r = post(replace(ticket, "login=alice" => "login=bob"))
            @test r["statusCode"] == 400 && isempty(seen["put"])
            n = match(r"&n=([0-9a-f]+)&", ticket).captures[1]
            expired = FB.signed(FB.signing_key("s3cret"), "ticket",
                "login=alice&primary=nightly&request=req-0002&link=$("0"^64)&n=$n&e=$(FB.now_s() - 1)")
            r = post(expired)
            @test r["statusCode"] == 400 && occursin("expired", r["body"])

            done = post(ticket)
            @test done["statusCode"] == 200
            @test occursin("Run submitted", done["body"])
            @test occursin("https://pkgeval-reports.julialang.org/?run=web-req-0001", done["body"])
            @test seen["session"] == ["alice-web"]
            put = JSON.parse(only(seen["put"]))
            item = put["Item"]
            @test put["ConditionExpression"] == "attribute_not_exists(run_id)"
            @test item["run_id"]["S"] == "web-req-0001"
            @test item["submitter"]["S"] == "alice"
            context = JSON.parse(item["context"]["S"])
            @test context["via"] == "web" && occursin(r"^[0-9a-f]{64}$", context["link"])
            @test JSON.parse(item["packages"]["S"]) == ["Example"]
            configs = JSON.parse(item["configs"]["S"])
            @test [c["julia"] for c in configs] == ["JuliaLang/julia#$sha", "v1.12.0"]
            @test item["reuse"]["BOOL"] == true
            @test JSON.parse(only(seen["send"])) == Dict("run_id" => "web-req-0001", "expand" => true)

            # a second click (or a resubmission) queues nothing new
            again = post(ticket)
            @test again["statusCode"] == 200
            @test occursin("Already submitted", again["body"])
            @test length(seen["send"]) == 1

            # the other tab still works
            @test post(ticket_of(page2["body"]))["statusCode"] == 200
            @test haskey(runs, "web-req-0004")

            # a different link reusing a request id is refused, not reported as its run
            other, _ = through_review("primary=JuliaLang/julia%23master&packages=Other&request=req-0001")
            r = post(ticket_of(other["body"]))
            @test r["statusCode"] == 409 && occursin("different submission", r["body"])
            @test length(seen["send"]) == 2

            # an unresolvable ref stops before review
            r, _ = through_review("primary=JuliaLang/julia%23nope&request=req-0003")
            @test r["statusCode"] == 400 && occursin("names no commit", r["body"])

            # invalid or oversized links never reach GitHub
            r = FB.handle_event(get_event("/submit", "primary=Evil/julia%23main"))
            @test r["statusCode"] == 400 && !haskey(r["headers"], "Location")
            long = join([rpad("Package$i", 40, "x") for i in 1:250], ",")
            r = FB.handle_event(get_event("/submit", "primary=nightly&packages=$long&request=req-0005"))
            @test r["statusCode"] == 414 && !haskey(r["headers"], "Location")
        end
    finally
        reset!()
        close(server)
    end
end

end # module
