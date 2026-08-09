"""
Build-request broker: asks Julia CI to build a commit that has no staged
artifact (a closed PR, an expired ephemeral artifact, a commit CI never built),
and reports back when that build *failed* — repeat asks poll the triggered
build's state, so a broken build turns into a `build-failed` answer the asker
can surface instead of a run stranded waiting for an artifact that will never
come.

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
                 json_string, json_int, isnullval, Attr, Item, attr, str, int,
                 json_item, parse_isodate
import .FarmLite: json_make

export handle_event

# Only ever this repository: the artifacts feed workers that execute the result.
const ALLOWED_REPO = "JuliaLang/julia"

# Build-state lifecycle bounds. A claim still lacking an artifact after
# MAX_BUILD_AGE is treated as failed whatever Buildkite says (the backstop for
# builds stuck queued forever, an unreachable API, or claims that predate
# build numbers being recorded). A *failed* claim older than FAILED_RETRY_AGE
# may be re-claimed and re-triggered, so a transient Buildkite failure costs a
# day, not the sha forever.
const MAX_BUILD_AGE = 3 * 60 * 60
const FAILED_RETRY_AGE = 24 * 60 * 60

# When upstream CI (julia-pr/julia-ci) is already building a commit, we wait on
# it instead of triggering a duplicate — its artifacts land in the same staging
# buckets workers probe. Once that upstream build reaches a terminal state and
# workers are *still* asking (i.e. the artifact never appeared, or upload lag),
# this grace period bounds the wait before we trigger our own build after all.
const UPSTREAM_DONE_GRACE = 10 * 60

api_base() = get(ENV, "BUILDKITE_API_BASE", "https://api.buildkite.com")
bk_token(ctx::LiteCtx) = ssm_parameter(ctx, ENV["BUILDKITE_TOKEN_PARAM"]::String)

"Pipelines whose in-flight builds of a commit we wait on rather than duplicate.
Empty disables the upstream check entirely."
upstream_pipelines() =
    split(get(ENV, "BUILDKITE_UPSTREAM_PIPELINES", "julia-pr,julia-ci"), ','; keepempty=false)

"The slice of a Buildkite build object this module reads."
struct BkBuild
    number::Union{Nothing,Int}
    state::Union{Nothing,String}
    web_url::Union{Nothing,String}
end

function json_make(::Type{BkBuild}, x::LazyVal)
    number = Ref{Union{Nothing,Int}}(nothing)
    state = Ref{Union{Nothing,String}}(nothing)
    web_url = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "number"
            n, p = json_int(v); number[] = Int(n); return p
        elseif k == "state"
            s, p = json_string(v); state[] = s; return p
        elseif k == "web_url"
            s, p = json_string(v); web_url[] = s; return p
        end
        return nothing
    end
    return BkBuild(number[], state[], web_url[]), pos::Int
end

function json_make(::Type{Vector{BkBuild}}, x::LazyVal)
    out = BkBuild[]
    pos = JSON.applyarray(x) do i, v
        b, p = json_make(BkBuild, v)
        push!(out, b)
        return p
    end
    return out, pos::Int
end

struct ItemResp                        # GetItem
    Item::Union{Nothing,Item}
end

function json_make(::Type{ItemResp}, x::LazyVal)
    item = Ref{Union{Nothing,Item}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "Item"
            i, p = json_make(Item, v); item[] = i; return p
        end
        return nothing
    end
    return ItemResp(item[]), pos::Int
end

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

isodate(t::DateTime=Dates.now(UTC)) = Dates.format(t, dateformat"yyyy-mm-dd\THH:MM:SS\Z")

is_sha(s::String) = length(s) == 40 && all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), s)

json_response(status::Int, body::String) =
    "{\"statusCode\":$status,\"headers\":{\"Content-Type\":\"application/json\"}," *
    "\"body\":$(JSON.json(body))}"

"""
Record the request so a commit is built once however many workers ask. Returns
false when someone got there first — the caller should then consult the claim
(`poll_claim`) rather than trigger a second identical build. A claim whose
build *failed* more than FAILED_RETRY_AGE ago may be taken over, giving
transiently-broken builds a bounded retry path.
"""
function claim_build(ctx::LiteCtx, table::String, key::String, requester::String)
    item = Item("build_key" => attr(key),
                "requested_at" => attr(isodate()),
                "requested_by" => attr(requester),
                "status" => attr("requested"))
    cutoff = isodate(Dates.now(UTC) - Dates.Second(FAILED_RETRY_AGE))
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Item\":$(json_item(item))," *
              "\"ConditionExpression\":\"attribute_not_exists(build_key) OR " *
              "(#s = :failed AND requested_at < :cutoff)\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{\":failed\":{\"S\":\"failed\"}," *
              "\":cutoff\":{\"S\":$(JSON.json(cutoff))}}}"
    try
        ddb(ctx, "PutItem", payload)
        return true
    catch err
        is_conditional_failure(err) || rethrow()
        return false
    end
end

function get_claim(ctx::LiteCtx, table::String, key::String)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}}"
    return parse_json(ddb(ctx, "GetItem", payload), ItemResp).Item
end

"Attach the triggered Buildkite build's identity to the claim, for later polls."
function record_build(ctx::LiteCtx, table::String, key::String, number::Int, url::String)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}," *
              "\"UpdateExpression\":\"SET build_number = :n, build_url = :u\"," *
              "\"ExpressionAttributeValues\":{\":n\":{\"N\":\"$number\"}," *
              "\":u\":{\"S\":$(JSON.json(url))}}}"
    ddb(ctx, "UpdateItem", payload)
    return nothing
end

function mark_build_failed(ctx::LiteCtx, table::String, key::String)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}," *
              "\"UpdateExpression\":\"SET #s = :failed\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{\":failed\":{\"S\":\"failed\"}}}"
    ddb(ctx, "UpdateItem", payload)
    return nothing
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
    # ignore_pipeline_branch_filters: the pipeline has branch builds disabled
    # (it is API-only by design), and Buildkite applies that filter to
    # API-created builds too — 422 "Branches have been disabled" without it.
    # Documented in julia-buildkite's pipelines/build_request/0_webui.yml.
    payload = "{\"commit\":$(JSON.json(sha))," *
              "\"branch\":$(JSON.json(sha))," *
              "\"message\":$(JSON.json("PkgEval build request ($variant)"))," *
              "\"ignore_pipeline_branch_filters\":true," *
              "\"env\":{\"PKGEVAL_BUILD_VARIANT\":$(JSON.json(variant))}}"
    url = "$(api_base())/v2/organizations/$org/pipelines/$pipeline/builds"
    resp = http_request("POST", url;
                        headers=["Authorization" => "Bearer $token",
                                 "Content-Type" => "application/json"],
                        body=payload)
    resp.status in (200, 201, 202) ||
        error("Buildkite trigger failed (HTTP $(resp.status)): $(resp.body)")
    # the response is the created build; its number is what later state polls
    # need (parse failures degrade to an identity-less claim, aged out later)
    return try
        parse_json(resp.body, BkBuild)
    catch
        BkBuild(nothing, nothing, nothing)
    end
end

"Fetch the current state of a build (\"running\", \"passed\", \"failed\", ...)."
function build_state(ctx::LiteCtx, pipeline::String, number::Int)
    org = ENV["BUILDKITE_ORG"]::String
    url = "$(api_base())/v2/organizations/$org/pipelines/$pipeline/builds/$number"
    resp = http_request("GET", url; headers=["Authorization" => "Bearer " * bk_token(ctx)])
    resp.status == 200 || error("Buildkite build query failed (HTTP $(resp.status))")
    return parse_json(resp.body, BkBuild).state
end
build_state(ctx::LiteCtx, number::Int) =
    build_state(ctx, ENV["BUILDKITE_PIPELINE"]::String, number)

# "blocked" deliberately doesn't count: a build waiting on a manual unblock
# may wait forever, and duplicating it is the lesser evil
upstream_active(state::String) = state in ("running", "scheduled", "creating")

"""
Find an upstream CI build of `sha` worth waiting on: one that is in flight, or
recently passed (its artifact may still be uploading). Returns
`(pipeline, number, url, active)` or `nothing` — including on any API trouble,
which degrades to triggering our own build, i.e. the pre-feature behavior.
"""
function find_upstream_build(ctx::LiteCtx, sha::String)
    org = ENV["BUILDKITE_ORG"]::String
    token = bk_token(ctx)
    for pipeline in upstream_pipelines()
        p = String(pipeline)
        builds = try
            url = "$(api_base())/v2/organizations/$org/pipelines/$p/builds?commit=$sha&per_page=10"
            resp = http_request("GET", url; headers=["Authorization" => "Bearer " * token])
            resp.status == 200 || continue
            parse_json(resp.body, Vector{BkBuild})
        catch err
            msg = (FarmLite.@trim_errmsg err)::String
            println(Core.stderr, "upstream build query failed for " * p * ": " * msg)
            continue
        end
        # prefer an in-flight build over a passed one; ignore failed/canceled
        # (they don't block us — and their artifacts, if any, would have been
        # found in the buckets before anyone asked here)
        passed = nothing
        for b in builds
            b.number === nothing && continue
            state = something(b.state, "")
            number = something(b.number)
            url = something(b.web_url, "")
            if upstream_active(state)
                return (p, number, url, true)
            elseif state == "passed" && passed === nothing
                passed = (p, number, url, false)
            end
        end
        passed === nothing || return passed
    end
    return nothing
end

"Flip a fresh claim to waiting-on-upstream, recording which build to poll."
function mark_claim_upstream(ctx::LiteCtx, table::String, key::String,
                             pipeline::String, number::Int, url::String, active::Bool)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}," *
              "\"UpdateExpression\":\"SET #s = :u, upstream_pipeline = :p, " *
              "upstream_number = :n, build_url = :url" *
              (active ? "" : ", upstream_done_at = :done") * "\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{\":u\":{\"S\":\"upstream\"}," *
              "\":p\":{\"S\":$(JSON.json(pipeline))}," *
              "\":n\":{\"N\":\"$number\"}," *
              "\":url\":{\"S\":$(JSON.json(url))}" *
              (active ? "" : ",\":done\":{\"S\":" * JSON.json(isodate()) * "}") * "}}"
    ddb(ctx, "UpdateItem", payload)
    return nothing
end

"Record when the upstream build was first seen terminal (starts the grace clock)."
function mark_upstream_done(ctx::LiteCtx, table::String, key::String)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}," *
              "\"ConditionExpression\":\"attribute_not_exists(upstream_done_at)\"," *
              "\"UpdateExpression\":\"SET upstream_done_at = :now\"," *
              "\"ExpressionAttributeValues\":{\":now\":{\"S\":$(JSON.json(isodate()))}}}"
    try
        ddb(ctx, "UpdateItem", payload)
    catch err
        is_conditional_failure(err) || rethrow()
    end
    return nothing
end

"""
Take over a claim whose upstream wait is done for (upstream failed, stalled
past the age backstop, or passed without an artifact appearing): flip it to a
normal `requested` claim — conditionally, so racing askers elect one trigger —
and fire our own build. Answers like the fresh-claim path.
"""
function takeover_and_trigger(ctx::LiteCtx, table::String, key::String,
                              commit::String, variant::String)
    payload = "{\"TableName\":$(JSON.json(table))," *
              "\"Key\":{\"build_key\":{\"S\":$(JSON.json(key))}}," *
              "\"ConditionExpression\":\"#s = :u\"," *
              "\"UpdateExpression\":\"SET #s = :r, requested_at = :now REMOVE upstream_done_at\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{\":u\":{\"S\":\"upstream\"}," *
              "\":r\":{\"S\":\"requested\"}," *
              "\":now\":{\"S\":$(JSON.json(isodate()))}}}"
    try
        ddb(ctx, "UpdateItem", payload)
    catch err
        is_conditional_failure(err) || rethrow()
        return pending_response(200, "already-requested", commit_builds_url(commit))
    end
    build = try
        trigger_build(bk_token(ctx),
                      ENV["BUILDKITE_ORG"]::String, ENV["BUILDKITE_PIPELINE"]::String,
                      commit, variant)
    catch err
        # release so the next asker retries the whole decision from scratch
        try
            release_build_claim(ctx, table, key)
        catch release_err
            msg = (FarmLite.@trim_errmsg release_err)::String
            println(Core.stderr, "failed to release build claim for " * key * ": " * msg)
        end
        rethrow()
    end
    if build.number !== nothing
        try
            record_build(ctx, table, key, something(build.number),
                         something(build.web_url, ""))
        catch err
            msg = (FarmLite.@trim_errmsg err)::String
            println(Core.stderr, "failed to record build identity for " * key * ": " * msg)
        end
    end
    url = something(build.web_url, "")
    return pending_response(202, "requested", isempty(url) ? commit_builds_url(commit) : url)
end

"""
Poll a claim that is waiting on an upstream CI build. Still in flight (and
young enough): keep waiting. Terminal, or stalled past MAX_BUILD_AGE: after a
grace period for artifact upload lag, stop waiting and trigger our own build —
never answer `build-failed` from here, since an upstream build's failure says
nothing about whether *our* build would succeed.
"""
function poll_upstream(ctx::LiteCtx, table::String, key::String, c::Item, url::String)
    variant = String(last(split(key, '/')))
    commit = String(first(split(key, '/')))
    asked = parse_isodate(str(c, "requested_at", ""))
    stalled = asked !== nothing &&
              Dates.now(UTC) - something(asked) >= Dates.Second(MAX_BUILD_AGE)
    stalled && return takeover_and_trigger(ctx, table, key, commit, variant)

    done_at = parse_isodate(str(c, "upstream_done_at", ""))
    if done_at !== nothing
        if Dates.now(UTC) - something(done_at) >= Dates.Second(UPSTREAM_DONE_GRACE)
            return takeover_and_trigger(ctx, table, key, commit, variant)
        end
        return pending_response(200, "already-requested", url)
    end

    pipeline = str(c, "upstream_pipeline", "")
    number = int(c, "upstream_number", -1)
    state = if isempty(pipeline) || number < 0
        nothing
    else
        try
            build_state(ctx, pipeline, number)
        catch err
            msg = (FarmLite.@trim_errmsg err)::String
            println(Core.stderr, "upstream state query failed for " * key * ": " * msg)
            nothing
        end
    end
    if state !== nothing && !upstream_active(something(state))
        mark_upstream_done(ctx, table, key)   # grace clock; next asks decide
    end
    return pending_response(200, "already-requested", url)
end

failed_response(url::String) =
    json_response(200, isempty(url) ? "{\"status\":\"build-failed\"}" :
                       "{\"status\":\"build-failed\",\"url\":" * JSON.json(url) * "}")

# Non-terminal answers carry a Buildkite URL too, so askers can surface *where*
# the wait is happening (the dashboard links it on stalled runs).
pending_response(code::Int, status::String, url::String) =
    json_response(code, isempty(url) ? "{\"status\":\"" * status * "\"}" :
                        "{\"status\":\"" * status * "\",\"url\":" * JSON.json(url) * "}")

"Buildkite's builds page filtered by commit: always a valid link, used when no
specific build identity is recorded on the claim."
commit_builds_url(commit::String) =
    "https://buildkite.com/" * (ENV["BUILDKITE_ORG"]::String) * "/" *
    (ENV["BUILDKITE_PIPELINE"]::String) * "/builds?commit=" * commit

"""
The dedup-hit path doubles as the failure detector: workers re-ask every
~10 minutes while an artifact is missing, so each hit polls Buildkite for the
triggered build's state. A failed/canceled build flips the claim to "failed"
and answers `build-failed` (with the build URL when known) — the asker turns
that into a run/job failure instead of waiting until the message dead-letters.
"""
function poll_claim(ctx::LiteCtx, table::String, key::String)
    claim = get_claim(ctx, table, key)
    # claim gone: released by a concurrent failed trigger; the asker's next
    # retry will re-claim
    claim === nothing && return pending_response(200, "already-requested",
                                                 commit_builds_url(String(first(split(key, '/')))))
    c = something(claim)::Item
    url = str(c, "build_url", "")
    if isempty(url)
        # claims without a recorded build identity (a trigger-response parse
        # failure, or predating identity recording) still deserve a link:
        # Buildkite's builds page filters by commit
        url = commit_builds_url(String(first(split(key, '/'))))
    end
    str(c, "status", "") == "failed" && return failed_response(url)
    str(c, "status", "") == "upstream" && return poll_upstream(ctx, table, key, c, url)
    asked = parse_isodate(str(c, "requested_at", ""))
    expired = asked !== nothing &&
              Dates.now(UTC) - something(asked) >= Dates.Second(MAX_BUILD_AGE)
    failed = expired
    if !failed
        number = int(c, "build_number", -1)
        if number >= 0
            state = try
                build_state(ctx, number)
            catch err
                # an unpollable build is not a failed one; the age backstop rules
                msg = (FarmLite.@trim_errmsg err)::String
                println(Core.stderr, "buildkite state query failed for " * key * ": " * msg)
                nothing
            end
            failed = state !== nothing &&
                     something(state) in ("failed", "canceled", "skipped", "not_run")
        end
    end
    failed || return pending_response(200, "already-requested", url)
    try
        mark_build_failed(ctx, table, key)
    catch err
        msg = (FarmLite.@trim_errmsg err)::String
        println(Core.stderr, "failed to mark build failed for " * key * ": " * msg)
    end
    return failed_response(url)
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
        return poll_claim(ctx, table, key)
    end

    # If upstream CI is already building (or just built) this commit, wait on
    # it instead of triggering a duplicate: its artifacts land in the same
    # staging buckets, so the workers' retry loop picks them up identically.
    # poll_upstream owns the wait from here — including falling back to our
    # own build if upstream fails, stalls, or passes without an artifact.
    upstream = try
        find_upstream_build(ctx, commit)
    catch err
        msg = (FarmLite.@trim_errmsg err)::String
        println(Core.stderr, "upstream check failed for " * key * ": " * msg)
        nothing
    end
    if upstream !== nothing
        pipeline, number, up_url, active = something(upstream)
        try
            mark_claim_upstream(ctx, table, key, pipeline, number, up_url, active)
            return pending_response(202, "waiting-upstream", up_url)
        catch err
            # an unmarkable claim must not wedge as a bare "requested" with no
            # build identity: release it and let the next asker redo the dance
            msg = (FarmLite.@trim_errmsg err)::String
            println(Core.stderr, "failed to mark upstream claim for " * key * ": " * msg)
            try
                release_build_claim(ctx, table, key)
            catch release_err
                msg2 = (FarmLite.@trim_errmsg release_err)::String
                println(Core.stderr, "failed to release build claim for " * key * ": " * msg2)
            end
            return pending_response(202, "waiting-upstream", up_url)
        end
    end

    # The claim is taken *before* the trigger (that is what makes it a dedup),
    # so a failed trigger must release it — otherwise one bad Buildkite call
    # poisons the key and every later ask no-ops as "already-requested"
    # forever. Seen live on the very first request.
    build = try
        trigger_build(bk_token(ctx),
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
    if build.number !== nothing
        try
            record_build(ctx, table, key, something(build.number),
                         something(build.web_url, ""))
        catch err
            # best effort: an identity-less claim still works, aged out later
            msg = (FarmLite.@trim_errmsg err)::String
            println(Core.stderr, "failed to record build identity for " * key * ": " * msg)
        end
    end
    url = something(build.web_url, "")
    return pending_response(202, "requested", isempty(url) ? commit_builds_url(commit) : url)
end

lambda_main() = lambda_loop(handle_event)

end # module
