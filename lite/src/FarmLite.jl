"""
FarmLite: a deliberately tiny, stdlib-only (+ JSON.jl) AWS/GitHub client shared by
the farm's juliac-compiled Lambdas (credential broker, @nanosoldier2 bot).

Not a package — `include` this file and `using .FarmLite`. Anything heavier (the
worker, the CLI) should use AWS.jl instead; this exists only because a trimmed static
binary cannot carry a full SDK. Written for `juliac --trim`: JSON responses are
parsed into concrete structs, and DynamoDB attribute values use a typed
representation (`Attr`) rather than `Any` trees.
"""
module FarmLite

using Dates
using Downloads
using JSON
using SHA

export HttpResponse, http_request, AwsCreds, env_creds, LiteCtx


## HTTP via Downloads (libcurl): works for the Lambda runtime API and HTTPS alike

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

function resp_header(resp::Downloads.Response, name::String)
    for (k, v) in resp.headers
        lowercase(k) == name && return v
    end
    error("missing $name header")
end


## SigV4 request signing

struct AwsCreds
    access_key_id::String
    secret_key::String
    token::Union{Nothing,String}
end

"Credentials from the Lambda/exec environment."
env_creds() = AwsCreds(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"],
                       get(ENV, "AWS_SESSION_TOKEN", nothing))

hmac(key, data) = hmac_sha256(Vector{UInt8}(key), data)
hexdigest(data) = bytes2hex(sha256(data))

urlencode(s::AbstractString) = sprint() do io
    for b in codeunits(s)
        c = Char(b)
        if isletter(c) && isascii(c) || isdigit(c) || c in ('-', '_', '.', '~')
            print(io, c)
        else
            print(io, '%', uppercase(string(b; base=16, pad=2)))
        end
    end
end

"""
    sigv4_headers(; method, host, path, body, region, service, creds,
                  content_type, extra_headers=[], time=now(UTC))

SigV4-sign a request, returning the headers to send (Authorization, the signed
headers, plus `Accept: application/json`). `extra_headers` participate in signing —
use them for `x-amz-target` (DynamoDB/SQS) and `x-amz-content-sha256` (S3).
"""
function sigv4_headers(; method::String, host::String, path::String, body::String,
                       region::String, service::String, creds::AwsCreds,
                       content_type::String="application/x-www-form-urlencoded; charset=utf-8",
                       extra_headers::Vector{Pair{String,String}}=Pair{String,String}[],
                       time::DateTime=Dates.now(UTC))
    timestamp = Dates.format(time, dateformat"yyyymmdd\THHMMSS\Z")
    date = timestamp[1:8]
    scope = "$date/$region/$service/aws4_request"

    headers = Pair{String,String}["content-type" => content_type,
                                  "host" => host,
                                  "x-amz-date" => timestamp]
    append!(headers, extra_headers)
    creds.token === nothing || push!(headers, "x-amz-security-token" => something(creds.token))
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
    result = Pair{String,String}["Authorization" => authorization,
                                 "Accept" => "application/json"]
    append!(result, filter(h -> first(h) != "host", headers))
    return result
end


## service plumbing

"Everything needed to reach one farm deployment with fixed credentials."
Base.@kwdef struct LiteCtx
    region::String
    creds::AwsCreds
    queue_url::String
    runs_table::String
    jobs_table::String
    bucket::String
    endpoint::Union{Nothing,String} = nothing  # emulator override (moto in tests)
end

function ctx_from_env()
    LiteCtx(; region=get(ENV, "FARM_REGION") do
                ENV["AWS_REGION"]  # set by the Lambda runtime; FARM_REGION elsewhere
            end, creds=env_creds(),
            queue_url=ENV["PKGEVAL_QUEUE_URL"], runs_table=ENV["PKGEVAL_RUNS_TABLE"],
            jobs_table=ENV["PKGEVAL_JOBS_TABLE"], bucket=ENV["PKGEVAL_BUCKET"],
            endpoint=get(ENV, "FARM_ENDPOINT", nothing))
end

host_of(url::String) = String(split(split(url, "://")[2], '/')[1])

function service_url(ctx::LiteCtx, service::String)
    ep = ctx.endpoint
    ep === nothing ? "https://$service.$(ctx.region).amazonaws.com/" : String(rstrip(ep, '/')) * "/"
end

"Signed POST of an `x-amz-json-1.0` operation (DynamoDB, SQS)."
function aws_json(ctx::LiteCtx, service::String, target::String, payload::String)
    url = service_url(ctx, service)
    headers = sigv4_headers(; method="POST", host=host_of(url), path="/", body=payload,
                            region=ctx.region, service, creds=ctx.creds,
                            content_type="application/x-amz-json-1.0",
                            extra_headers=["x-amz-target" => target])
    resp = http_request("POST", url; headers, body=payload)
    resp.status == 200 ||
        error("$target failed (HTTP $(resp.status)): $(resp.body)")
    return resp.body
end

ddb(ctx::LiteCtx, op::String, payload::String) =
    aws_json(ctx, "dynamodb", "DynamoDB_20120810.$op", payload)

"Whether an error thrown by `ddb` was a failed ConditionExpression."
is_conditional_failure(err) = err isa ErrorException &&
    (occursin("ConditionalCheckFailed", err.msg) ||
     occursin("conditional request failed", lowercase(err.msg)))

function sqs_send_message(ctx::LiteCtx, body::String)
    payload = JSON.json((; QueueUrl=ctx.queue_url, MessageBody=body))
    aws_json(ctx, "sqs", "AmazonSQS.SendMessage", payload)
    return nothing
end

"Signed S3 PUT (path-style against emulators, virtual-hosted otherwise)."
function s3_put(ctx::LiteCtx, key::String, body::String; content_type::String="text/plain; charset=utf-8")
    if ctx.endpoint === nothing
        host = "$(ctx.bucket).s3.$(ctx.region).amazonaws.com"
        url = "https://$host/$key"
        path = "/" * key
    else
        host = host_of(ctx.endpoint)
        url = String(rstrip(ctx.endpoint, '/')) * "/$(ctx.bucket)/$key"
        path = "/$(ctx.bucket)/$key"
    end
    path = join(map(urlencode, split(path, '/')), '/')
    headers = sigv4_headers(; method="PUT", host, path, body,
                            region=ctx.region, service="s3", creds=ctx.creds,
                            content_type,
                            extra_headers=["x-amz-content-sha256" => hexdigest(body)])
    resp = http_request("PUT", url; headers, body)
    resp.status == 200 || error("S3 PUT $key failed (HTTP $(resp.status)): $(resp.body)")
    return nothing
end


## typed DynamoDB attribute values (concrete structs keep `juliac --trim` happy)

"One DynamoDB attribute value; exactly one field is non-nothing."
struct Attr
    S::Union{Nothing,String}
    N::Union{Nothing,String}
    BOOL::Union{Nothing,Bool}
    NULL::Union{Nothing,Bool}
    L::Union{Nothing,Vector{Attr}}
    M::Union{Nothing,Dict{String,Attr}}
end
Attr(; S=nothing, N=nothing, BOOL=nothing, NULL=nothing, L=nothing, M=nothing) =
    Attr(S, N, BOOL, NULL, L, M)

const Item = Dict{String,Attr}

attr(v::String) = Attr(; S=v)
attr(v::Bool) = Attr(; BOOL=v)
attr(v::Real) = Attr(; N=string(v))
attr(::Nothing) = Attr(; NULL=true)

# typed accessors; a wrong type is a schema bug and errors loudly
str(item::Item, key::String) = something(item[key].S)::String
str(item::Item, key::String, default::String) =
    haskey(item, key) && item[key].S !== nothing ? something(item[key].S) : default
int(item::Item, key::String) = parse(Int, something(item[key].N)::String)
opt_str(item::Item, key::String) = haskey(item, key) ? item[key].S : nothing

function json_attr(io::IO, a::Attr)
    if a.S !== nothing
        print(io, "{\"S\":", JSON.json(something(a.S)), "}")
    elseif a.N !== nothing
        print(io, "{\"N\":\"", something(a.N), "\"}")
    elseif a.BOOL !== nothing
        print(io, "{\"BOOL\":", something(a.BOOL), "}")
    elseif a.NULL !== nothing
        print(io, "{\"NULL\":true}")
    else
        error("unsupported Attr")
    end
end

function json_item(item::Item)
    io = IOBuffer()
    print(io, "{")
    first_entry = true
    for (k, v) in item
        first_entry || print(io, ",")
        first_entry = false
        print(io, JSON.json(k), ":")
        json_attr(io, v)
    end
    print(io, "}")
    return String(take!(io))
end


## Lambda custom runtime loop

"Trim-friendly error rendering (`sprint(showerror, ::Any)` cannot be trimmed)."
function error_message(err)
    if err isa ErrorException
        return err.msg
    elseif err isa ArgumentError
        return err.msg
    elseif err isa KeyError
        return "missing key: $(string(err.key)::String)"
    elseif err isa Downloads.RequestError
        return "request to $(err.url) failed: $(err.message) (code $(err.code))"
    else
        return "unexpected error of type $(String(nameof(typeof(err))))"
    end
end

"""
    lambda_loop(handle)

Run the Lambda custom-runtime loop forever: fetch each invocation, call
`handle(event_body::String)::String`, and post the returned JSON as the response.
"""
function lambda_loop(handle::F) where {F}
    api = ENV["AWS_LAMBDA_RUNTIME_API"]
    next_url = "http://$api/2018-06-01/runtime/invocation/next"
    while true
        request_id = ""
        try
            output = IOBuffer()
            resp = Downloads.request(next_url; method="GET", output,
                                     headers=["User-Agent" => "PkgEvalFarm"])
            resp isa Downloads.Response || error("unexpected runtime API response")
            request_id = resp_header(resp, "lambda-runtime-aws-request-id")
            response = handle(String(take!(output)))
            http_request("POST",
                "http://$api/2018-06-01/runtime/invocation/$request_id/response";
                body=response)
        catch err
            msg = error_message(err)
            @error "invocation failed" msg
            isempty(request_id) && continue
            try
                http_request("POST",
                    "http://$api/2018-06-01/runtime/invocation/$request_id/error";
                    body="{\"errorType\":\"FarmError\",\"errorMessage\":$(JSON.json(msg))}")
            catch
            end
        end
    end
end


## GitHub REST

struct GitHubCtx
    token::String
    api_base::String   # overridable for tests
end
GitHubCtx(token::String) = GitHubCtx(token, "https://api.github.com")

function github_request(gh::GitHubCtx, method::String, path::String;
                        body::Union{String,Nothing}=nothing)
    url = startswith(path, "http") ? path : gh.api_base * path
    http_request(method, url;
                 headers=["Authorization" => "Bearer $(gh.token)",
                          "Accept" => "application/vnd.github+json",
                          "X-GitHub-Api-Version" => "2022-11-28",
                          "User-Agent" => "PkgEvalFarm-bot"],
                 body)
end

end # module
