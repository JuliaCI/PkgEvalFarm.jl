"""
Build-request broker: asks Julia CI to build a commit that has no staged
artifact (a closed PR, an expired ephemeral artifact, a commit CI never built).

Workers must be able to request builds, but must not hold the credential that
does it: they run arbitrary package code. So the Buildkite trigger URL lives in
an SSM parameter only this Lambda can read, and workers reach the Lambda through
a Function URL with `AWS_IAM` authorization — SigV4 with the credentials they
already have, no new secret anywhere.

The credential is a Buildkite REST API token belonging to a *machine user* whose
team membership grants access to the build-request pipeline and nothing else:
scope names like `write_builds` are organization-wide, but the user's pipeline
permissions bound what the token can actually reach. Unlike an incoming webhook
trigger, the REST API takes the commit as a parameter — so the build is attested
to the commit it was asked for, and the token can be rotated.

The pipeline is still responsible for verifying the sha is a real
JuliaLang/julia commit before building it.
"""
module BuildRequest

using Dates
using JSON
import Downloads  # @trim_errmsg escapes into this module and names Downloads.RequestError

include(joinpath(@__DIR__, "..", "..", "lite", "src", "FarmLite.jl"))
using .FarmLite
using .FarmLite: LiteCtx, ctx_from_env, ssm_parameter, ddb, is_conditional_failure,
                 http_request, lambda_loop, error_message, LazyVal, parse_json,
                 json_string, isnullval, Attr, Item, attr, str, json_item
import .FarmLite: json_make

export handle_event

# Only ever this repository: the artifacts feed workers that execute the result.
const ALLOWED_REPO = "JuliaLang/julia"

struct BuildAsk
    repo::Union{Nothing,String}
    sha::Union{Nothing,String}
    variant::Union{Nothing,String}   # "linux" (default) or "linuxassert"
end

function json_make(::Type{BuildAsk}, x::LazyVal)
    repo = Ref{Union{Nothing,String}}(nothing)
    sha = Ref{Union{Nothing,String}}(nothing)
    variant = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "repo"
            s, p = json_string(v); repo[] = s; return p
        elseif k == "sha"
            s, p = json_string(v); sha[] = s; return p
        elseif k == "variant"
            s, p = json_string(v); variant[] = s; return p
        end
        return nothing
    end
    return BuildAsk(repo[], sha[], variant[]), pos::Int
end

struct FnUrlEvent
    method::Union{Nothing,String}
    body::Union{Nothing,String}
    is_base64::Bool
end

function json_make(::Type{FnUrlEvent}, x::LazyVal)
    method = Ref{Union{Nothing,String}}(nothing)
    body = Ref{Union{Nothing,String}}(nothing)
    is_base64 = Ref(false)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "requestContext"
            # NB: distinct local names per nesting level. Reusing `s`/`p` from
            # the enclosing closure makes Julia box the shared capture to Any,
            # which juliac --trim cannot verify.
            return JSON.applyobject(v) do rk, rv
                rk == "http" || return nothing
                JSON.applyobject(rv) do hk, hv
                    if hk == "method"
                        mstr, mpos = json_string(hv); method[] = mstr; return mpos
                    end
                    return nothing
                end
            end
        elseif k == "body"
            s, p = json_string(v); body[] = s; return p
        elseif k == "isBase64Encoded"
            b, p = FarmLite.json_bool(v); is_base64[] = b; return p
        end
        return nothing
    end
    return FnUrlEvent(method[], body[], is_base64[]), pos::Int
end

isodate() = Dates.format(Dates.now(UTC), dateformat"yyyy-mm-dd\THH:MM:SS\Z")

is_sha(s::String) = length(s) == 40 && all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), s)

json_response(status::Int, body::String) =
    "{\"statusCode\":$status,\"headers\":{\"Content-Type\":\"application/json\"}," *
    "\"body\":$(JSON.json(body))}"

"""
Record the request so a commit is built once however many workers ask. Returns
false when someone got there first — the caller should simply wait for the
artifact rather than trigger a second identical build.
"""
function claim_build(ctx::LiteCtx, table::String, key::String, requester::String)
    item = Item("build_key" => attr(key),
                "requested_at" => attr(isodate()),
                "requested_by" => attr(requester),
                "status" => attr("requested"))
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Item\":$(json_item(item))," *
              "\"ConditionExpression\":\"attribute_not_exists(build_key)\"}"
    try
        ddb(ctx, "PutItem", payload)
        return true
    catch err
        is_conditional_failure(err) || rethrow()
        return false
    end
end

"Release a claim whose trigger failed, so the next asker retries the trigger."
function release_build_claim(ctx::LiteCtx, table::String, key::String)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}}"
    ddb(ctx, "DeleteItem", payload)
    return nothing
end

"Ask Buildkite to build one commit. The token's reach is bounded by the machine user's team access."
function trigger_build(token::String, org::String, pipeline::String,
                       sha::String, variant::String)
    # `branch` is required by the API but the agent checks out `commit`; naming
    # it after the sha keeps the build list readable and avoids implying the
    # commit is on master.
    payload = "{\"commit\":$(JSON.json(sha))," *
              "\"branch\":$(JSON.json(sha))," *
              "\"message\":$(JSON.json("PkgEval build request ($variant)"))," *
              "\"env\":{\"PKGEVAL_BUILD_VARIANT\":$(JSON.json(variant))}}"
    url = "https://api.buildkite.com/v2/organizations/$org/pipelines/$pipeline/builds"
    resp = http_request("POST", url;
                        headers=["Authorization" => "Bearer $token",
                                 "Content-Type" => "application/json"],
                        body=payload)
    resp.status in (200, 201, 202) ||
        error("Buildkite trigger failed (HTTP $(resp.status)): $(resp.body)")
    return nothing
end

function handle_event(event_body::String, ctx::LiteCtx=ctx_from_env())
    event = parse_json(event_body, FnUrlEvent)
    raw = if event.method === nothing
        # not a Function-URL event: a direct Lambda Invoke, whose payload is
        # the BuildAsk JSON itself (the workers' path; see request_julia_build)
        event_body
    else
        event.method == "POST" || return json_response(405, "{\"error\":\"POST only\"}")
        b = something(event.body, "")
        event.is_base64 ? String(FarmLite.base64decode_lite(b)) : b
    end
    ask = try
        parse_json(raw, BuildAsk)
    catch
        return json_response(400, "{\"error\":\"body must be {repo, sha, variant?}\"}")
    end

    repo = something(ask.repo, ALLOWED_REPO)
    repo == ALLOWED_REPO ||
        # literal rather than interpolated: interpolating even a const global
        # emits a `string(::Any...)` call the trim verifier cannot resolve
        return json_response(403, "{\"error\":\"only JuliaLang/julia builds may be requested\"}")
    sha = ask.sha
    (sha !== nothing && is_sha(something(sha))) ||
        return json_response(400, "{\"error\":\"sha must be a 40-character commit hash\"}")
    variant = something(ask.variant, "linux")
    variant in ("linux", "linuxassert") ||
        return json_response(400, "{\"error\":\"variant must be linux or linuxassert\"}")

    table = ENV["PKGEVAL_BUILDS_TABLE"]::String
    commit = something(sha)::String
    key = string(commit, "/", variant)
    if !claim_build(ctx, table, key, "lambda")
        return json_response(200, "{\"status\":\"already-requested\"}")
    end

    # The claim is taken *before* the trigger (that is what makes it a dedup),
    # so a failed trigger must release it — otherwise one bad Buildkite call
    # poisons the key and every later ask no-ops as "already-requested"
    # forever. Seen live on the very first request.
    try
        trigger_build(ssm_parameter(ctx, ENV["BUILDKITE_TOKEN_PARAM"]::String),
                      ENV["BUILDKITE_ORG"]::String, ENV["BUILDKITE_PIPELINE"]::String,
                      commit, variant)
    catch
        try
            release_build_claim(ctx, table, key)
        catch release_err
            # @trim_errmsg: `error_message(::Any)` on a caught exception is an
            # unverifiable dynamic call under --trim=safe
            msg = (FarmLite.@trim_errmsg release_err)::String
            println(Core.stderr, "failed to release build claim for " * key * ": " * msg)
        end
        rethrow()
    end
    return json_response(202, "{\"status\":\"requested\"}")
end

lambda_main() = lambda_loop(handle_event)

end # module
