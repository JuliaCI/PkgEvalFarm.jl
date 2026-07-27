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

The module is written to compile under `juliac --trim=safe`: incoming JSON is
materialized into concrete structs by walking JSON.jl's lazy values with concrete
closures (the generic `StructUtils.make` machinery is deliberately unspecialized on
the target type, which the trim verifier rejects), outgoing JSON is serialized from
concrete structs with `JSON.json`, and error reporting avoids the dynamic
`showerror` machinery.
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
    resp isa Downloads.Response ||
        error("unexpected response type from Downloads.request")
    return HttpResponse(resp.status, String(take!(output)))
end


## configuration (all injected by terraform as Lambda environment variables)

env(key::String) = get(ENV, key) do
    error("broker misconfigured: missing environment variable $key")
end::String

role_team(role::String) = role == "worker" ? env("WORKER_TEAM") :
                          role == "submitter" ? env("SUBMITTER_TEAM") :
                          nothing
role_arn(role::String) = role == "worker" ? env("WORKER_ROLE_ARN") : env("SUBMITTER_ROLE_ARN")

"Farm resource locations, returned alongside credentials (JSON object keys = field names)."
struct FarmConfig
    region::String
    queue_url::String
    slow_queue_url::String
    runs_table::String
    jobs_table::String
    bucket::String
end

farm_config() = FarmConfig(env("FARM_REGION"), env("PKGEVAL_QUEUE_URL"),
                           get(ENV, "PKGEVAL_SLOW_QUEUE_URL", "")::String,
                           env("PKGEVAL_RUNS_TABLE"), env("PKGEVAL_JOBS_TABLE"),
                           env("PKGEVAL_BUCKET"))


## typed JSON parsing: a small materialization layer over JSON.jl's lazy parser.
## JSON.jl does all the actual parsing (lexing, string unescaping, number parsing);
## we only walk the lazy values with fully-concrete closures so that every call is
## statically resolvable under `juliac --trim=safe`.

const LazyVal = JSON.LazyValue{String}

@noinline json_expected(what::String) = error("malformed JSON: expected " * what)

jsontype(v::LazyVal) = JSON.gettype(v)
isnullval(v::LazyVal) = jsontype(v) == JSON.JSONTypes.NULL

function json_string(v::LazyVal)
    jsontype(v) == JSON.JSONTypes.STRING || json_expected("string")
    s, pos = JSON.parsestring(v)
    return convert(String, s)::String, pos
end

function json_bool(v::LazyVal)
    t = jsontype(v)
    t == JSON.JSONTypes.TRUE && return true, JSON.getpos(v) + 4
    t == JSON.JSONTypes.FALSE && return false, JSON.getpos(v) + 5
    json_expected("boolean")
end

function json_string_dict(v::LazyVal)
    dict = Dict{String,String}()
    pos = JSON.applyobject(v) do k, val
        s, p = json_string(val)
        dict[convert(String, k)::String] = s
        return p
    end
    return dict, pos::Int
end

"Parse `buf` into `T` via `json_make`, checking that the whole input is consumed."
function parse_json(buf::String, ::Type{T}) where {T}
    x = JSON.lazy(buf)
    v, pos = json_make(T, x)
    JSON.checkendpos(x, T, pos)
    return v
end


## GitHub

function github_get(path::AbstractString, token::AbstractString)
    http_request("GET", "https://api.github.com" * path;
                 headers=["Authorization" => "Bearer $token",
                          "Accept" => "application/vnd.github+json",
                          "User-Agent" => "PkgEvalFarm-broker"])
end

struct GitHubUser
    login::Union{Nothing,String}
end

function json_make(::Type{GitHubUser}, x::LazyVal)
    login = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "login"
            s, p = json_string(v); login[] = s; return p
        end
        return nothing
    end
    return GitHubUser(login[]), pos::Int
end

"Resolve the token to a GitHub login, or `nothing` if the token is invalid."
function github_user(token)
    resp = github_get("/user", token)
    resp.status == 200 || return nothing
    login = parse_json(resp.body, GitHubUser).login
    login === nothing && error("malformed GitHub /user response: missing login")
    return login
end

struct GitHubOrg
    login::Union{Nothing,String}
end

struct GitHubTeam
    slug::Union{Nothing,String}
    organization::Union{Nothing,GitHubOrg}
end

function json_make(::Type{GitHubOrg}, x::LazyVal)
    login = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "login"
            s, p = json_string(v); login[] = s; return p
        end
        return nothing
    end
    return GitHubOrg(login[]), pos::Int
end

function json_make(::Type{GitHubTeam}, x::LazyVal)
    slug = Ref{Union{Nothing,String}}(nothing)
    organization = Ref{Union{Nothing,GitHubOrg}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "slug"
            s, p = json_string(v); slug[] = s; return p
        elseif k == "organization"
            o, p = json_make(GitHubOrg, v); organization[] = o; return p
        end
        return nothing
    end
    return GitHubTeam(slug[], organization[]), pos::Int
end

function json_make(::Type{Vector{GitHubTeam}}, x::LazyVal)
    jsontype(x) == JSON.JSONTypes.ARRAY || json_expected("array")
    teams = GitHubTeam[]
    pos = JSON.applyarray(x) do i, v
        t, p = json_make(GitHubTeam, v)
        push!(teams, t)
        return p
    end
    return teams, pos::Int
end

"Whether the token's user is a member of `org`'s team `team_slug` (needs read:org)."
function team_member(token, org::String, team_slug::String)
    for page in 1:10
        resp = github_get("/user/teams?per_page=100&page=$page", token)
        resp.status == 200 || return false
        teams = parse_json(resp.body, Vector{GitHubTeam})
        for team in teams
            slug = team.slug
            organization = team.organization
            (slug === nothing || organization === nothing) && continue
            org_login = organization.login
            org_login === nothing && continue
            if lowercase(org_login) == lowercase(org) &&
               lowercase(slug) == lowercase(team_slug)
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

# a struct rather than a NamedTuple: a Union-typed NamedTuple field makes the whole
# tuple type abstract, which turns keyword calls passing it into dynamic dispatch
# that `juliac --trim` rejects (sigv4_headers itself stays duck-typed)
struct AwsCredentials
    access_key_id::String
    secret_key::String
    token::Union{Nothing,String}
end

lambda_creds() = AwsCredentials(env("AWS_ACCESS_KEY_ID"), env("AWS_SECRET_ACCESS_KEY"),
                                get(ENV, "AWS_SESSION_TOKEN", nothing))

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

"The credentials handed back to the caller (JSON object keys = field names)."
struct Credentials
    access_key_id::String
    secret_access_key::String
    session_token::String
    expiration::String
end

# the shape of the STS AssumeRole JSON response; Expiration is materialized
# directly to the ISO-formatted string we hand out
struct STSCredentialsIn
    AccessKeyId::Union{Nothing,String}
    SecretAccessKey::Union{Nothing,String}
    SessionToken::Union{Nothing,String}
    Expiration::Union{Nothing,String}
end

# JSON responses use epoch seconds for Expiration, but be liberal and accept a
# preformatted string too
function json_expiration(v::LazyVal)
    t = jsontype(v)
    if t == JSON.JSONTypes.STRING
        return json_string(v)
    elseif t == JSON.JSONTypes.NUMBER
        num, pos = JSON.parsenumber(v)
        seconds = JSON.isint(num) ? Float64(num.int) :
                  JSON.isfloat(num) ? num.float :
                  JSON.isbigint(num) ? Float64(num.bigint) : Float64(num.bigfloat)
        return Dates.format(Dates.unix2datetime(seconds),
                            dateformat"yyyy-mm-dd\THH:MM:SS\Z"), pos
    end
    json_expected("expiration")
end

function json_make(::Type{STSCredentialsIn}, x::LazyVal)
    access_key_id = Ref{Union{Nothing,String}}(nothing)
    secret_access_key = Ref{Union{Nothing,String}}(nothing)
    session_token = Ref{Union{Nothing,String}}(nothing)
    expiration = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "AccessKeyId"
            s, p = json_string(v); access_key_id[] = s; return p
        elseif k == "SecretAccessKey"
            s, p = json_string(v); secret_access_key[] = s; return p
        elseif k == "SessionToken"
            s, p = json_string(v); session_token[] = s; return p
        elseif k == "Expiration"
            s, p = json_expiration(v); expiration[] = s; return p
        end
        return nothing
    end
    return STSCredentialsIn(access_key_id[], secret_access_key[],
                            session_token[], expiration[]), pos::Int
end

# {"AssumeRoleResponse": {"AssumeRoleResult": {"Credentials": {...}}}}
function json_make(::Type{STSCredentialsIn}, x::LazyVal, path::NTuple{N,String}) where {N}
    creds = Ref{Union{Nothing,STSCredentialsIn}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == path[1]
            c, p = N == 1 ? json_make(STSCredentialsIn, v) :
                            json_make(STSCredentialsIn, v, Base.tail(path))
            creds[] = c
            return p
        end
        return nothing
    end
    return creds[], pos::Int
end

function assume_role(arn::AbstractString, session_name::AbstractString;
                     duration::Int=3600, region::AbstractString=env("FARM_REGION"))
    # STS_ENDPOINT trades the real endpoint for a local emulator in tests
    endpoint = get(ENV, "STS_ENDPOINT", "https://sts.$region.amazonaws.com")
    host = String(split(split(endpoint, "://")[2], '/')[1])
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
    if startswith(lstrip(resp.body), "{")
        x = JSON.lazy(resp.body)
        creds, _ = json_make(STSCredentialsIn, x,
                             ("AssumeRoleResponse", "AssumeRoleResult", "Credentials"))
        creds === nothing && error("malformed STS response: missing Credentials")
        access_key_id = creds.AccessKeyId
        secret_access_key = creds.SecretAccessKey
        session_token = creds.SessionToken
        expiration = creds.Expiration
        (access_key_id === nothing || secret_access_key === nothing ||
         session_token === nothing || expiration === nothing) &&
            error("malformed STS response: incomplete Credentials")
        return Credentials(access_key_id, secret_access_key, session_token, expiration)
    else
        field = name -> begin
            m = match(Regex("<$name>([^<]+)</$name>"), resp.body)
            m === nothing && error("malformed STS response: missing $name")
            String(something(m.captures[1]))
        end
        return Credentials(field("AccessKeyId"), field("SecretAccessKey"),
                           field("SessionToken"), field("Expiration"))
    end
end


## request handling

"A Lambda Function URL response (serialized as {\"statusCode\":..,\"headers\":..,\"body\":..})."
struct FunctionUrlResponse
    statusCode::Int
    headers::Dict{String,String}
    body::String
end

# dict-style access, so callers (and the unit tests) can treat it like the JSON object
function Base.getindex(r::FunctionUrlResponse, key::String)
    key == "statusCode" && return r.statusCode
    key == "headers" && return r.headers
    key == "body" && return r.body
    throw(KeyError(key))
end

struct InfoPayload
    client_id::String
    org::String
    worker_team::String
    submitter_team::String
end

struct ErrorPayload
    error::String
end

struct CredsPayload
    user::String
    role::String
    credentials::Credentials
    config::FarmConfig
end

json_response(status::Int, payload) =
    FunctionUrlResponse(status, Dict("Content-Type" => "application/json"),
                        JSON.json(payload))
error_response(status::Int, message::AbstractString) =
    json_response(status, ErrorPayload(String(message)))

# the (subset of the) Lambda Function URL event shape we care about
struct EventHttp
    method::Union{Nothing,String}
end
struct EventRequestContext
    http::Union{Nothing,EventHttp}
end
struct LambdaEvent
    rawPath::Union{Nothing,String}
    requestContext::Union{Nothing,EventRequestContext}
    headers::Union{Nothing,Dict{String,String}}
    body::Union{Nothing,String}
    isBase64Encoded::Union{Nothing,Bool}
end

function json_make(::Type{EventHttp}, x::LazyVal)
    method = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "method"
            s, p = json_string(v); method[] = s; return p
        end
        return nothing
    end
    return EventHttp(method[]), pos::Int
end

function json_make(::Type{EventRequestContext}, x::LazyVal)
    http = Ref{Union{Nothing,EventHttp}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "http"
            h, p = json_make(EventHttp, v); http[] = h; return p
        end
        return nothing
    end
    return EventRequestContext(http[]), pos::Int
end

function json_make(::Type{LambdaEvent}, x::LazyVal)
    rawPath = Ref{Union{Nothing,String}}(nothing)
    requestContext = Ref{Union{Nothing,EventRequestContext}}(nothing)
    headers = Ref{Union{Nothing,Dict{String,String}}}(nothing)
    body = Ref{Union{Nothing,String}}(nothing)
    isBase64Encoded = Ref{Union{Nothing,Bool}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "rawPath"
            s, p = json_string(v); rawPath[] = s; return p
        elseif k == "requestContext"
            c, p = json_make(EventRequestContext, v); requestContext[] = c; return p
        elseif k == "headers"
            d, p = json_string_dict(v); headers[] = d; return p
        elseif k == "body"
            s, p = json_string(v); body[] = s; return p
        elseif k == "isBase64Encoded"
            b, p = json_bool(v); isBase64Encoded[] = b; return p
        end
        return nothing
    end
    return LambdaEvent(rawPath[], requestContext[], headers[], body[],
                       isBase64Encoded[]), pos::Int
end

# accessors shared between the raw-Dict event form (kept for interactive use and the
# unit tests) and the typed LambdaEvent form used by the compiled runtime loop
event_method(event::AbstractDict) =
    get(get(get(event, "requestContext", Dict()), "http", Dict()), "method", "GET")
event_path(event::AbstractDict) = get(event, "rawPath", "/")
event_auth(event::AbstractDict) = begin
    headers = get(event, "headers", Dict())
    get(headers, "authorization", get(headers, "Authorization", ""))
end
event_body(event::AbstractDict) = something(get(event, "body", ""), "")
event_isbase64(event::AbstractDict) = get(event, "isBase64Encoded", false)

function event_method(event::LambdaEvent)
    requestContext = event.requestContext
    requestContext === nothing && return "GET"
    http = requestContext.http
    http === nothing && return "GET"
    return something(http.method, "GET")
end
event_path(event::LambdaEvent) = something(event.rawPath, "/")
function event_auth(event::LambdaEvent)
    headers = event.headers
    headers === nothing && return ""
    return get(headers, "authorization", get(headers, "Authorization", ""))
end
event_body(event::LambdaEvent) = something(event.body, "")
event_isbase64(event::LambdaEvent) = something(event.isBase64Encoded, false)

"Handle one Lambda Function URL event, returning the Function URL response."
function handle_event(event::Union{AbstractDict,LambdaEvent})
    method = event_method(event)
    path = rstrip(event_path(event), '/')

    if method == "GET" && path == "/info"
        return json_response(200, InfoPayload(
            env("GITHUB_CLIENT_ID"), env("GITHUB_ORG"),
            env("WORKER_TEAM"), env("SUBMITTER_TEAM")))
    elseif method == "POST" && path == "/creds"
        return handle_creds(event)
    end
    return error_response(404, "not found")
end

function bearer_token(event)
    auth = event_auth(event)
    m = match(r"^(?:Bearer|token)\s+(\S+)$"i, auth)
    return m === nothing ? nothing : String(something(m.captures[1]))
end

struct RoleRequest
    role::Union{Nothing,String}
end

function json_make(::Type{RoleRequest}, x::LazyVal)
    role = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "role"
            s, p = json_string(v); role[] = s; return p
        end
        return nothing
    end
    return RoleRequest(role[]), pos::Int
end

function handle_creds(event)
    token = bearer_token(event)
    token === nothing && return error_response(401, "missing Authorization header")

    body = event_body(event)
    event_isbase64(event) && (body = String(base64decode_compat(body)))
    role = try
        r = parse_json(isempty(body) ? "{}" : body, RoleRequest).role
        r === nothing && error("missing role")
        r
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
    return json_response(200, CredsPayload(user, role, credentials, farm_config()))
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

struct RuntimeError
    errorType::String
    errorMessage::String
end

# render the caught exception without the dynamic `showerror` machinery, which
# `juliac --trim` cannot compile (the catch slot is typed `Any`, so this must be an
# inlined isa-chain rather than a dispatched call)
macro trim_errmsg(err)
    esc(quote
        local e = $err
        if e isa ErrorException
            e.msg
        elseif e isa ArgumentError
            e.msg
        elseif e isa Downloads.RequestError
            "request to " * e.url * " failed: " * e.message * " (code " * string(e.code) * ")"
        else
            "unexpected error of type " * String(nameof(typeof(e)))
        end
    end)
end

function run_loop()
    api = env("AWS_LAMBDA_RUNTIME_API")
    next_url = "http://$api/2018-06-01/runtime/invocation/next"
    while true
        request_id = ""
        try
            output = IOBuffer()
            resp = Downloads.request(next_url; method="GET", output,
                                     headers=["User-Agent" => "FarmBroker"])
            resp isa Downloads.Response ||
                error("unexpected response type from the Lambda runtime API")
            event = parse_json(String(take!(output)), LambdaEvent)
            request_id = resp_header(resp, "lambda-runtime-aws-request-id")
            response = handle_event(event)
            http_request("POST",
                "http://$api/2018-06-01/runtime/invocation/$request_id/response";
                body=JSON.json(response))
        catch err
            msg = @trim_errmsg(err)::String
            println(Core.stderr, "invocation failed: ", msg)
            isempty(request_id) && continue
            try
                http_request("POST",
                    "http://$api/2018-06-01/runtime/invocation/$request_id/error";
                    body=JSON.json(RuntimeError("BrokerError", msg)))
            catch
            end
        end
    end
end

function resp_header(resp::Downloads.Response, name::String)
    for (k, v) in resp.headers
        lowercase(k) == name && return v
    end
    error("missing $name header from the Lambda runtime API")
end

end # module
