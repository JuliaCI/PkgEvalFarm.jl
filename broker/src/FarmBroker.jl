"""
The PkgEvalFarm credential broker.

A Lambda (custom runtime, statically compiled with juliac) that exchanges a GitHub
user token for short-lived, least-privilege AWS credentials:

    GET  /info   -> public config (OAuth client id, org/team names) for the CLI
    POST /creds  {"role": "worker"|"submitter"}, Authorization: Bearer <github token>
                 -> STS credentials + farm resource locations

Authorization is GitHub team membership (checked with the caller's own token, so the
broker itself holds no GitHub secrets): the teams are configured via `GITHUB_ORG`,
`WORKER_TEAM` and `SUBMITTER_TEAM`, and map to the IAM roles `WORKER_ROLE_ARN` /
`SUBMITTER_ROLE_ARN`.

Deliberately stdlib-only (+ JSON.jl): HTTP via `Downloads`, SigV4 via `SHA`, and the
single STS call is hand-signed rather than pulling a full AWS SDK into the binary.
"""
module FarmBroker

using Dates
using Downloads
using JSON
using SHA

export handle_event, run_loop


## small HTTP client on top of Downloads (works for both the runtime API and HTTPS)

struct HttpResponse
    status::Int
    body::String
end

function http_request(method::AbstractString, url::AbstractString;
                      headers::Vector{Pair{String,String}}=Pair{String,String}[],
                      body::Union{String,Nothing}=nothing)
    output = IOBuffer()
    input = body === nothing ? nothing : IOBuffer(body)
    resp = Downloads.request(url; method=String(method), headers, input, output,
                             throw=true)
    return HttpResponse(resp.status, String(take!(output)))
end


## configuration (all injected by terraform as Lambda environment variables)

env(key) = get(ENV, key) do
    error("broker misconfigured: missing environment variable $key")
end

role_team(role) = role == "worker" ? env("WORKER_TEAM") :
                  role == "submitter" ? env("SUBMITTER_TEAM") :
                  nothing
role_arn(role) = role == "worker" ? env("WORKER_ROLE_ARN") : env("SUBMITTER_ROLE_ARN")

farm_config() = Dict(
    "region" => env("FARM_REGION"),
    "queue_url" => env("PKGEVAL_QUEUE_URL"),
    "runs_table" => env("PKGEVAL_RUNS_TABLE"),
    "jobs_table" => env("PKGEVAL_JOBS_TABLE"),
    "bucket" => env("PKGEVAL_BUCKET"))


## GitHub

function github_get(path::AbstractString, token::AbstractString)
    http_request("GET", "https://api.github.com" * path;
                 headers=["Authorization" => "Bearer $token",
                          "Accept" => "application/vnd.github+json",
                          "User-Agent" => "PkgEvalFarm-broker"])
end

"Resolve the token to a GitHub login, or `nothing` if the token is invalid."
function github_user(token)
    resp = github_get("/user", token)
    resp.status == 200 || return nothing
    return JSON.parse(resp.body)["login"]::String
end

"Whether the token's user is a member of `org`'s team `team_slug` (needs read:org)."
function team_member(token, org, team_slug)
    for page in 1:10
        resp = github_get("/user/teams?per_page=100&page=$page", token)
        resp.status == 200 || return false
        teams = JSON.parse(resp.body)
        for team in teams
            if lowercase(team["organization"]["login"]) == lowercase(org) &&
               lowercase(team["slug"]) == lowercase(team_slug)
                return true
            end
        end
        length(teams) < 100 && break
    end
    return false
end


## STS AssumeRole, SigV4-signed by hand, JSON response via Accept header

hmac(key, data) = hmac_sha256(Vector{UInt8}(key), data)
hexdigest(data) = bytes2hex(sha256(data))

function sigv4_headers(; method, host, path, body, region, service, creds,
                       time::DateTime=Dates.now(UTC))
    timestamp = Dates.format(time, dateformat"yyyymmdd\THHMMSS\Z")
    date = timestamp[1:8]
    scope = "$date/$region/$service/aws4_request"

    headers = ["content-type" => "application/x-www-form-urlencoded; charset=utf-8",
               "host" => host,
               "x-amz-date" => timestamp]
    creds.token === nothing || push!(headers, "x-amz-security-token" => creds.token)
    sort!(headers; by=first)
    signed_headers = join(first.(headers), ";")

    canonical = join([method, path, "",
                      join(["$k:$v" for (k, v) in headers], "\n"), "",
                      signed_headers, hexdigest(body)], "\n")
    string_to_sign = join(["AWS4-HMAC-SHA256", timestamp, scope, hexdigest(canonical)], "\n")
    key = foldl(hmac, [date, region, service, "aws4_request"];
                init=Vector{UInt8}("AWS4" * creds.secret_key))
    signature = bytes2hex(hmac(key, string_to_sign))

    authorization = "AWS4-HMAC-SHA256 Credential=$(creds.access_key_id)/$scope, " *
                    "SignedHeaders=$signed_headers, Signature=$signature"
    return [("Authorization" => authorization);
            ["Accept" => "application/json"];
            filter(h -> first(h) != "host", headers)]
end

lambda_creds() = (; access_key_id=env("AWS_ACCESS_KEY_ID"),
                  secret_key=env("AWS_SECRET_ACCESS_KEY"),
                  token=get(ENV, "AWS_SESSION_TOKEN", nothing))

urlencode(s) = sprint() do io
    for b in codeunits(s)
        c = Char(b)
        if isletter(c) && isascii(c) || isdigit(c) || c in ('-', '_', '.', '~')
            print(io, c)
        else
            print(io, '%', uppercase(string(b; base=16, pad=2)))
        end
    end
end

function assume_role(arn::AbstractString, session_name::AbstractString;
                     duration::Int=3600, region::AbstractString=env("FARM_REGION"))
    # STS_ENDPOINT trades the real endpoint for a local emulator in tests
    endpoint = get(ENV, "STS_ENDPOINT", "https://sts.$region.amazonaws.com")
    host = split(split(endpoint, "://")[2], '/')[1]
    # session names allow only a small character set; GitHub logins fit after mapping
    session_name = replace(session_name, r"[^\w+=,.@-]" => "-")
    body = join(["Action=AssumeRole", "Version=2011-06-15",
                 "RoleArn=" * urlencode(arn),
                 "RoleSessionName=" * urlencode(session_name),
                 "DurationSeconds=$duration"], "&")
    headers = sigv4_headers(; method="POST", host, path="/", body,
                            region, service="sts", creds=lambda_creds())
    resp = http_request("POST", "$endpoint/"; headers, body)
    resp.status == 200 || error("STS AssumeRole failed (HTTP $(resp.status)): $(resp.body)")

    # STS answers JSON when asked via Accept, but be liberal and take XML too (some
    # emulators ignore Accept); the fields we need are flat either way
    field = if startswith(lstrip(resp.body), "{")
        creds = JSON.parse(resp.body)["AssumeRoleResponse"]["AssumeRoleResult"]["Credentials"]
        name -> creds[name]
    else
        name -> begin
            m = match(Regex("<$name>([^<]+)</$name>"), resp.body)
            m === nothing && error("malformed STS response: missing $name")
            m.captures[1]
        end
    end
    expiration = field("Expiration")
    if expiration isa Number  # JSON responses use epoch seconds
        expiration = Dates.format(Dates.unix2datetime(expiration),
                                  dateformat"yyyy-mm-dd\THH:MM:SS\Z")
    end
    return Dict("access_key_id" => field("AccessKeyId"),
                "secret_access_key" => field("SecretAccessKey"),
                "session_token" => field("SessionToken"),
                "expiration" => String(expiration))
end


## request handling

json_response(status, payload) =
    Dict("statusCode" => status,
         "headers" => Dict("Content-Type" => "application/json"),
         "body" => JSON.json(payload))
error_response(status, message) = json_response(status, Dict("error" => message))

"Handle one Lambda Function URL event, returning the Function URL response dict."
function handle_event(event::AbstractDict)
    method = get(get(get(event, "requestContext", Dict()), "http", Dict()), "method", "GET")
    path = rstrip(get(event, "rawPath", "/"), '/')

    if method == "GET" && path == "/info"
        return json_response(200, Dict(
            "client_id" => env("GITHUB_CLIENT_ID"),
            "org" => env("GITHUB_ORG"),
            "worker_team" => env("WORKER_TEAM"),
            "submitter_team" => env("SUBMITTER_TEAM")))
    elseif method == "POST" && path == "/creds"
        return handle_creds(event)
    end
    return error_response(404, "not found")
end

function bearer_token(event)
    headers = get(event, "headers", Dict())
    auth = get(headers, "authorization", get(headers, "Authorization", ""))
    m = match(r"^(?:Bearer|token)\s+(\S+)$"i, auth)
    return m === nothing ? nothing : String(m.captures[1])
end

function handle_creds(event)
    token = bearer_token(event)
    token === nothing && return error_response(401, "missing Authorization header")

    body = something(get(event, "body", ""), "")
    get(event, "isBase64Encoded", false) && (body = String(base64decode_compat(body)))
    role = try
        String(JSON.parse(isempty(body) ? "{}" : body)["role"])
    catch
        return error_response(400, "request body must be {\"role\": \"worker\"|\"submitter\"}")
    end
    team = role_team(role)
    team === nothing && return error_response(400, "unknown role: $role")

    user = github_user(token)
    user === nothing && return error_response(401, "invalid GitHub token")
    org = env("GITHUB_ORG")
    team_member(token, org, team) ||
        return error_response(403,
            "@$user is not a member of $org/$team; membership in that team " *
            "(with the token granted read:org) is required for the '$role' role")

    duration = parse(Int, get(ENV, "CRED_DURATION", "3600"))
    credentials = assume_role(role_arn(role), user; duration)
    return json_response(200, Dict("user" => user, "role" => role,
                                   "credentials" => credentials,
                                   "config" => farm_config()))
end

# Base64 without pulling in the Base64 stdlib's IO machinery (juliac-friendly)
function base64decode_compat(s::AbstractString)
    lookup = fill(0xff, 256)
    for (i, c) in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        lookup[Int(c)+1] = UInt8(i - 1)
    end
    out = UInt8[]
    acc = 0; nbits = 0
    for c in s
        c in ('=', '\n', '\r') && continue
        v = lookup[Int(c)+1]
        v == 0xff && error("invalid base64")
        acc = (acc << 6) | v; nbits += 6
        if nbits >= 8
            nbits -= 8
            push!(out, UInt8((acc >> nbits) & 0xff))
        end
    end
    return out
end


## Lambda custom runtime loop

function run_loop()
    api = env("AWS_LAMBDA_RUNTIME_API")
    next_url = "http://$api/2018-06-01/runtime/invocation/next"
    while true
        request_id = ""
        try
            output = IOBuffer()
            resp = Downloads.request(next_url; method="GET", output,
                                     headers=["User-Agent" => "FarmBroker"])
            event = JSON.parse(String(take!(output)))
            request_id = resp_header(resp, "lambda-runtime-aws-request-id")
            response = handle_event(event)
            http_request("POST",
                "http://$api/2018-06-01/runtime/invocation/$request_id/response";
                body=JSON.json(response))
        catch err
            msg = sprint(showerror, err)
            @error "invocation failed" exception=err
            isempty(request_id) && continue
            try
                http_request("POST",
                    "http://$api/2018-06-01/runtime/invocation/$request_id/error";
                    body=JSON.json(Dict("errorType" => "BrokerError", "errorMessage" => msg)))
            catch
            end
        end
    end
end

function resp_header(resp, name)
    for (k, v) in resp.headers
        lowercase(k) == name && return v
    end
    error("missing $name header from the Lambda runtime API")
end

end # module
