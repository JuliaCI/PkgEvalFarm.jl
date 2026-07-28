"""
FarmLite: a deliberately tiny, stdlib-only (+ JSON.jl) AWS/GitHub client shared by
the farm's juliac-compiled Lambdas (credential broker, @pkgeval bot).

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
    # long-jobs queue; expand messages ride it (expansion is a long job). Falls
    # back to queue_url when the deployment is single-queue.
    slow_queue_url::String = ""
    runs_table::String
    jobs_table::String
    bucket::String
    endpoint::Union{Nothing,String} = nothing  # emulator override (moto in tests)
end

slow_queue(ctx::LiteCtx) =
    isempty(ctx.slow_queue_url) ? ctx.queue_url : ctx.slow_queue_url

function ctx_from_env()
    LiteCtx(; region=get(ENV, "FARM_REGION") do
                ENV["AWS_REGION"]  # set by the Lambda runtime; FARM_REGION elsewhere
            end, creds=env_creds(),
            queue_url=ENV["PKGEVAL_QUEUE_URL"],
            slow_queue_url=get(ENV, "PKGEVAL_SLOW_QUEUE_URL", "")::String,
            runs_table=ENV["PKGEVAL_RUNS_TABLE"],
            jobs_table=ENV["PKGEVAL_JOBS_TABLE"], bucket=ENV["PKGEVAL_BUCKET"],
            endpoint=get(ENV, "FARM_ENDPOINT", nothing))
end

host_of(url::String) = String(split(split(url, "://")[2], '/')[1])

function service_url(ctx::LiteCtx, service::String)
    ep = ctx.endpoint
    ep === nothing ? "https://$service.$(ctx.region).amazonaws.com/" : String(rstrip(ep, '/')) * "/"
end

"Signed POST of an `x-amz-json-1.0` operation (DynamoDB, SQS)."
function aws_json(ctx::LiteCtx, service::String, target::String, payload::String;
                  content_type::String="application/x-amz-json-1.0")
    url = service_url(ctx, service)
    headers = sigv4_headers(; method="POST", host=host_of(url), path="/", body=payload,
                            region=ctx.region, service, creds=ctx.creds,
                            content_type,
                            extra_headers=["x-amz-target" => target])
    resp = http_request("POST", url; headers, body=payload)
    resp.status == 200 ||
        error("$target failed (HTTP $(resp.status)): $(resp.body)")
    return resp.body
end

ddb(ctx::LiteCtx, op::String, payload::String) =
    aws_json(ctx, "dynamodb", "DynamoDB_20120810.$op", payload)

"Whether an error thrown by `ddb` was a failed ConditionExpression."
function is_conditional_failure(err)
    err isa ErrorException || return false
    msg = err.msg
    msg isa String || return false  # narrow the AbstractString field for juliac --trim
    return occursin("ConditionalCheckFailed", msg) ||
           occursin("conditional request failed", lowercase(msg))
end

function sqs_send_message(ctx::LiteCtx, body::String;
                          queue_url::String=ctx.queue_url)
    payload = JSON.json((; QueueUrl=queue_url, MessageBody=body))
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


## typed JSON parsing: a small materialization layer over JSON.jl's lazy parser.
## JSON.jl does all the actual parsing (lexing, string unescaping, number parsing);
## we only walk the lazy values with fully-concrete closures so that every call is
## statically resolvable under `juliac --trim=safe` (the generic `StructUtils.make`
## machinery, and thus typed `JSON.parse(buf, T)`, is deliberately unspecialized on
## the target type, which the trim verifier rejects). Consumers define
## `json_make(::Type{T}, ::LazyVal)` methods for their own shapes.

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

function json_int(v::LazyVal)
    jsontype(v) == JSON.JSONTypes.NUMBER || json_expected("integer")
    num, pos = JSON.parsenumber(v)
    n = JSON.isint(num) ? num.int :
        JSON.isfloat(num) ? Int64(num.float) : json_expected("integer")
    return n::Int64, pos
end

function json_string_vector(v::LazyVal)
    jsontype(v) == JSON.JSONTypes.ARRAY || json_expected("array of strings")
    out = String[]
    pos = JSON.applyarray(v) do i, val
        s, p = json_string(val)
        push!(out, s)
        return p
    end
    return out, pos::Int
end

"`json_make(::Type{T}, ::LazyVal) -> (value::T, pos::Int)`; see `parse_json`."
function json_make end

"Parse `buf` into `T` via `json_make`, checking that the whole input is consumed."
function parse_json(buf::String, ::Type{T}) where {T}
    x = JSON.lazy(buf)
    v, pos = json_make(T, x)
    JSON.checkendpos(x, T, pos)
    return v
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
int(item::Item, key::String, default::Int) =
    haskey(item, key) && item[key].N !== nothing ? parse(Int, something(item[key].N)) : default
flt(item::Item, key::String, default::Float64) =
    haskey(item, key) && item[key].N !== nothing ?
        something(tryparse(Float64, something(item[key].N)), default) : default
opt_str(item::Item, key::String) = haskey(item, key) ? item[key].S : nothing

"""
Parse the fixed-layout UTC timestamps this codebase writes
("2026-07-28T15:30:00Z"), or `nothing` on any mismatch. Hand-rolled because
`DateTime(str, dateformat)`'s error path dispatches dynamically, which the
`juliac --trim` verifier rejects.
"""
function parse_isodate(s::String)
    (ncodeunits(s) == 20 && isascii(s) &&
     s[5] == '-' && s[8] == '-' && s[11] == 'T' &&
     s[14] == ':' && s[17] == ':' && s[20] == 'Z') || return nothing
    y = tryparse(Int, s[1:4]);   mo = tryparse(Int, s[6:7])
    d = tryparse(Int, s[9:10]);  h = tryparse(Int, s[12:13])
    mi = tryparse(Int, s[15:16]); se = tryparse(Int, s[18:19])
    (y === nothing || mo === nothing || d === nothing ||
     h === nothing || mi === nothing || se === nothing) && return nothing
    (1 <= something(mo) <= 12 &&
     1 <= something(d) <= Dates.daysinmonth(something(y), something(mo)) &&
     something(h) <= 23 && something(mi) <= 59 && something(se) <= 59) || return nothing
    return DateTime(something(y), something(mo), something(d),
                    something(h), something(mi), something(se))
end

# lazy materializers for attribute values ("Attr" is recursive through L and M);
# the explicit return types break the recursive inference cycle, which would
# otherwise widen to Any and fail the trim verifier
function json_make(::Type{Attr}, x::LazyVal)::Tuple{Attr,Int}
    S = Ref{Union{Nothing,String}}(nothing)
    N = Ref{Union{Nothing,String}}(nothing)
    BOOL = Ref{Union{Nothing,Bool}}(nothing)
    NULL = Ref{Union{Nothing,Bool}}(nothing)
    L = Ref{Union{Nothing,Vector{Attr}}}(nothing)
    M = Ref{Union{Nothing,Dict{String,Attr}}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "S"
            s, p = json_string(v); S[] = s; return p
        elseif k == "N"
            s, p = json_string(v); N[] = s; return p
        elseif k == "BOOL"
            b, p = json_bool(v); BOOL[] = b; return p
        elseif k == "NULL"
            b, p = json_bool(v); NULL[] = b; return p
        elseif k == "L"
            l, p = json_make(Vector{Attr}, v); L[] = l; return p
        elseif k == "M"
            m, p = json_make(Item, v); M[] = m; return p
        end
        return nothing
    end
    return Attr(S[], N[], BOOL[], NULL[], L[], M[]), pos::Int
end

function json_make(::Type{Vector{Attr}}, x::LazyVal)::Tuple{Vector{Attr},Int}
    jsontype(x) == JSON.JSONTypes.ARRAY || json_expected("attribute list")
    out = Attr[]
    pos = JSON.applyarray(x) do i, v
        a, p = json_make(Attr, v)
        push!(out, a)
        return p
    end
    return out, pos::Int
end

function json_make(::Type{Item}, x::LazyVal)::Tuple{Item,Int}
    item = Item()
    pos = JSON.applyobject(x) do k, v
        a, p = json_make(Attr, v)
        item[convert(String, k)::String] = a
        return p
    end
    return item, pos::Int
end

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


## SSM (parameters hold credentials that must never reach a worker)

struct SsmParameterValue
    Value::Union{Nothing,String}
end
struct SsmGetParameterResult
    Parameter::Union{Nothing,SsmParameterValue}
end

function json_make(::Type{SsmParameterValue}, x::LazyVal)
    value = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "Value"
            s, p = json_string(v); value[] = s; return p
        end
        return nothing
    end
    return SsmParameterValue(value[]), pos::Int
end

function json_make(::Type{SsmGetParameterResult}, x::LazyVal)
    param = Ref{Union{Nothing,SsmParameterValue}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "Parameter"
            p_, p = json_make(SsmParameterValue, v); param[] = p_; return p
        end
        return nothing
    end
    return SsmGetParameterResult(param[]), pos::Int
end

"Read a (SecureString) parameter. SSM speaks JSON 1.1, unlike DynamoDB/SQS."
function ssm_parameter(ctx::LiteCtx, name::String)
    payload = "{\"Name\":$(JSON.json(name)),\"WithDecryption\":true}"
    body = aws_json(ctx, "ssm", "AmazonSSM.GetParameter", payload;
                    content_type="application/x-amz-json-1.1")
    result = parse_json(body, SsmGetParameterResult)
    result.Parameter === nothing && error("no such SSM parameter: $name")
    value = something(result.Parameter).Value
    value === nothing && error("SSM parameter has no value: $name")
    # Secrets never legitimately carry surrounding whitespace, and a trailing
    # newline (easy to store by accident) is catastrophic downstream: inside an
    # Authorization header it terminates the HTTP header block early, so the
    # request authenticates but loses its remaining headers and body. Seen
    # live: Buildkite answering "Problems parsing JSON" to a build trigger.
    return String(strip(something(value)))
end


## GitHub webhook verification

"""
    valid_signature(secret, body, signature) -> Bool

Verify a GitHub webhook `X-Hub-Signature-256` header (constant-time comparison).
"""
function valid_signature(secret::String, body::String,
                         signature::Union{Nothing,String})
    (isempty(secret) || signature === nothing) && return false
    sig = something(signature)
    expected = "sha256=" * bytes2hex(hmac_sha256(Vector{UInt8}(secret), body))
    ncodeunits(sig) == ncodeunits(expected) || return false
    diff = UInt8(0)
    for (a, b) in zip(codeunits(sig), codeunits(expected))
        diff |= a ⊻ b
    end
    return diff == 0x00
end

# Base64 without the Base64 stdlib's IO machinery (juliac-friendly)
function base64decode_lite(s::AbstractString)
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

"""
    @trim_errmsg err

Trim-friendly error rendering (`sprint(showerror, ::Any)` cannot be trimmed, and
neither can a function call dispatched on the `Any`-typed catch slot — hence a
macro that expands to an inlined isa-chain).
"""
macro trim_errmsg(err)
    esc(quote
        local e = $err
        if e isa ErrorException
            e.msg
        elseif e isa ArgumentError
            e.msg
        elseif e isa KeyError
            local k = e.key
            k isa String ? "missing key: " * k : "missing key"
        elseif e isa Downloads.RequestError
            "request to " * e.url * " failed: " * e.message * " (code " * string(e.code) * ")"
        else
            "unexpected error of type " * String(nameof(typeof(e)))
        end
    end)
end

"Function form of `@trim_errmsg` for callers with a narrowed exception type."
error_message(err) = @trim_errmsg err

"""
    lambda_loop(handle)

Run the Lambda custom-runtime loop forever: fetch each invocation, call
`handle(event_body::String)::String`, and post the returned JSON as the response.
"""
# The `next` long poll is the one request that must be allowed to stall
# indefinitely: Lambda freezes the process while it waits and thaws it when an
# event arrives, at which point libcurl sees minutes of wall clock with zero
# bytes moved and Downloads' stalled-transfer guard (1 byte/s over 20s) aborts
# the request — eating the very invocation that woke us. The guard is disabled
# through a Downloader easy_hook; in the trimmed Lambdas that hook must be the
# concretely-typed `Downloads.FarmEasyHook` from the trim-compat layer, because
# the stock `easy_hook` dispatch (`invokelatest` on an arbitrary Function) is
# unverifiable and stubbed out there. Anywhere else a plain closure works.
# (A raw-socket client would avoid libcurl entirely, but Sockets' uv_readcb
# is itself trim-incompatible, so this is the road that exists.)
disable_low_speed_hook() =
    isdefined(Downloads, :FarmEasyHook) ? Downloads.FarmEasyHook() :
    (easy, _) -> begin
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_LIMIT, 0)
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, 0)
    end

function lambda_loop(handle::F) where {F}
    api = ENV["AWS_LAMBDA_RUNTIME_API"]::String
    next_url = "http://$api/2018-06-01/runtime/invocation/next"
    next_dl = Downloads.Downloader()
    next_dl.easy_hook = disable_low_speed_hook()
    while true
        request_id = ""
        try
            output = IOBuffer()
            resp = Downloads.request(next_url; method="GET", output, downloader=next_dl,
                                     headers=["User-Agent" => "PkgEvalFarm"])
            resp isa Downloads.Response || error("unexpected runtime API response")
            request_id = resp_header(resp, "lambda-runtime-aws-request-id")
            response = handle(String(take!(output)))
            http_request("POST",
                "http://$api/2018-06-01/runtime/invocation/$request_id/response";
                body=response)
        catch err
            msg = (@trim_errmsg err)::String
            println(Core.stderr, "invocation failed: ", msg)
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
