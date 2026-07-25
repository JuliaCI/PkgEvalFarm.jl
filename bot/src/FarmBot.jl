"""
The @pkgeval bot: turns GitHub PR comments (`@pkgeval runtests(...)`) into
farm runs and posts the report back when a run finishes.

Deployed as a juliac-compiled Lambda invoked on an EventBridge schedule; each
invocation performs one poll (mentions + finished runs). It carries the submitter IAM
policy on its execution role, so unlike human submitters it needs neither the broker
nor GitHub team membership — only its GitHub account token, read from the SSM
parameter named by `BOT_TOKEN_PARAM` (or, outside Lambda, from `BOT_GITHUB_TOKEN`).

All state lives in the runs table and GitHub, so the bot is also runnable anywhere
else (`farm bot` runs the same code in a polling loop).
"""
module FarmBot

using Dates
using JSON

include(joinpath(@__DIR__, "..", "..", "lite", "src", "FarmLite.jl"))
using .FarmLite
using .FarmLite: Attr, Item, attr, str, int, opt_str, json_item, ddb, sqs_send_message,
                 s3_put, is_conditional_failure, GitHubCtx, github_request, urlencode,
                 error_message, lambda_loop, ctx_from_env, ssm_parameter,
                 LazyVal, parse_json, json_string, json_bool, json_int,
                 json_string_vector, jsontype, isnullval, json_expected
import .FarmLite: json_make

export run_bot, handle_invocation


## command parsing (pure)

# the command may be wrapped in backticks — `runtests(...)` — which is how
# classic Nanosoldier documents it and how people habitually write it
const BOT_COMMAND = r"@([\w-]+)\s+`?runtests\((.*?)\)`?"s

struct Command
    packages::Vector{String}
    vs::Union{Nothing,String}
    error::Union{Nothing,String}
end

"""
    parse_command(body) -> Union{Nothing,Command}

Parse a `@<bot> runtests(...)` comment (backticks around the command are
allowed, matching classic Nanosoldier usage). Supported forms:

    runtests()                    all packages
    runtests(["Foo", "Bar"])      a subset
    runtests(vs = ":master")      against a branch of the same repo
    runtests(vs = "@0123abc")     against a commit of the same repo
    runtests(vs = "v1.12.0")      against a Julia release

The argument expression is parsed, never evaluated.
"""
function parse_command(body::AbstractString)
    m = match(BOT_COMMAND, body)
    m === nothing && return nothing
    packages = String[]
    vs = nothing
    args = strip(something(m.captures[2]))
    if !isempty(args)
        expr = try
            Meta.parse("runtests($args)")
        catch
            return Command(packages, vs, "could not parse command arguments")
        end
        Meta.isexpr(expr, :call) || return Command(packages, vs, "could not parse command arguments")
        for arg in (expr::Expr).args[2:end]
            if (Meta.isexpr(arg, :kw) || Meta.isexpr(arg, :(=))) &&
               (arg::Expr).args[1] === :vs && (arg::Expr).args[2] isa String
                vs = (arg::Expr).args[2]::String
            elseif Meta.isexpr(arg, :vect) && all(x -> x isa String, (arg::Expr).args)
                packages = String[x::String for x in (arg::Expr).args]
            elseif arg === :ALL
                # explicit "all packages"
            else
                # description via an isa-chain: `string(::Any)` on the expression
                # would pull the (untimmable) Expr-show machinery into the binary
                argdesc = arg isa Symbol ? String(arg) :
                          arg isa String ? arg :
                          arg isa Number ? "a number" : "an expression"
                return Command(packages, vs, "unsupported argument `$argdesc`")
            end
        end
    end
    return Command(packages, vs, nothing)
end

"Resolve a `vs` spec against the repo the PR targets."
function resolve_vs(vs::AbstractString, repo::AbstractString)
    startswith(vs, ":") && return "$repo#$(chop(vs; head=1, tail=0))"
    startswith(vs, "@") && return "$repo#$(chop(vs; head=1, tail=0))"
    return String(vs)
end


## GitHub response shapes (concrete structs; unknown JSON fields are skipped)

struct NotificationSubject
    type::Union{Nothing,String}
    url::Union{Nothing,String}
    latest_comment_url::Union{Nothing,String}
end
struct Notification
    id::Union{Nothing,String}
    reason::Union{Nothing,String}
    subject::Union{Nothing,NotificationSubject}
end
struct GhUser
    login::Union{Nothing,String}
end
struct GhComment
    id::Union{Nothing,Int}
    body::Union{Nothing,String}
    user::Union{Nothing,GhUser}
end
struct GhPrRef
    url::Union{Nothing,String}
end
struct GhIssue
    number::Union{Nothing,Int}
    repository_url::Union{Nothing,String}
    pull_request::Union{Nothing,GhPrRef}
end
struct GhCommit
    sha::Union{Nothing,String}
    ref::Union{Nothing,String}
end
struct GhPr
    head::Union{Nothing,GhCommit}
    base::Union{Nothing,GhCommit}
end

# lazy materializers (see FarmLite.parse_json: typed `JSON.parse(body, T)` cannot
# pass the `juliac --trim=safe` verifier, so shapes are built by walking JSON.jl's
# lazy values with concrete closures)

function json_make(::Type{NotificationSubject}, x::LazyVal)
    type = Ref{Union{Nothing,String}}(nothing)
    url = Ref{Union{Nothing,String}}(nothing)
    latest_comment_url = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "type"
            s, p = json_string(v); type[] = s; return p
        elseif k == "url"
            s, p = json_string(v); url[] = s; return p
        elseif k == "latest_comment_url"
            s, p = json_string(v); latest_comment_url[] = s; return p
        end
        return nothing
    end
    return NotificationSubject(type[], url[], latest_comment_url[]), pos::Int
end

function json_make(::Type{Notification}, x::LazyVal)
    id = Ref{Union{Nothing,String}}(nothing)
    reason = Ref{Union{Nothing,String}}(nothing)
    subject = Ref{Union{Nothing,NotificationSubject}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "id"
            s, p = json_string(v); id[] = s; return p
        elseif k == "reason"
            s, p = json_string(v); reason[] = s; return p
        elseif k == "subject"
            s, p = json_make(NotificationSubject, v); subject[] = s; return p
        end
        return nothing
    end
    return Notification(id[], reason[], subject[]), pos::Int
end

function json_make(::Type{Vector{Notification}}, x::LazyVal)
    jsontype(x) == JSON.JSONTypes.ARRAY || json_expected("array")
    out = Notification[]
    pos = JSON.applyarray(x) do i, v
        n, p = json_make(Notification, v)
        push!(out, n)
        return p
    end
    return out, pos::Int
end

function json_make(::Type{GhUser}, x::LazyVal)
    login = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "login"
            s, p = json_string(v); login[] = s; return p
        end
        return nothing
    end
    return GhUser(login[]), pos::Int
end

function json_make(::Type{GhComment}, x::LazyVal)
    id = Ref{Union{Nothing,Int}}(nothing)
    body = Ref{Union{Nothing,String}}(nothing)
    user = Ref{Union{Nothing,GhUser}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "id"
            n, p = json_int(v); id[] = Int(n); return p
        elseif k == "body"
            s, p = json_string(v); body[] = s; return p
        elseif k == "user"
            u, p = json_make(GhUser, v); user[] = u; return p
        end
        return nothing
    end
    return GhComment(id[], body[], user[]), pos::Int
end

function json_make(::Type{GhPrRef}, x::LazyVal)
    url = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "url"
            s, p = json_string(v); url[] = s; return p
        end
        return nothing
    end
    return GhPrRef(url[]), pos::Int
end

function json_make(::Type{GhIssue}, x::LazyVal)
    number = Ref{Union{Nothing,Int}}(nothing)
    repository_url = Ref{Union{Nothing,String}}(nothing)
    pull_request = Ref{Union{Nothing,GhPrRef}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "number"
            n, p = json_int(v); number[] = Int(n); return p
        elseif k == "repository_url"
            s, p = json_string(v); repository_url[] = s; return p
        elseif k == "pull_request"
            r, p = json_make(GhPrRef, v); pull_request[] = r; return p
        end
        return nothing
    end
    return GhIssue(number[], repository_url[], pull_request[]), pos::Int
end

function json_make(::Type{GhCommit}, x::LazyVal)
    sha = Ref{Union{Nothing,String}}(nothing)
    ref = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "sha"
            s, p = json_string(v); sha[] = s; return p
        elseif k == "ref"
            s, p = json_string(v); ref[] = s; return p
        end
        return nothing
    end
    return GhCommit(sha[], ref[]), pos::Int
end

function json_make(::Type{GhPr}, x::LazyVal)
    head = Ref{Union{Nothing,GhCommit}}(nothing)
    base = Ref{Union{Nothing,GhCommit}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "head"
            c, p = json_make(GhCommit, v); head[] = c; return p
        elseif k == "base"
            c, p = json_make(GhCommit, v); base[] = c; return p
        end
        return nothing
    end
    return GhPr(head[], base[]), pos::Int
end


## DynamoDB response shapes

struct ItemsResp                       # Scan / Query
    Items::Union{Nothing,Vector{Item}}
    LastEvaluatedKey::Union{Nothing,Item}
end
struct ItemResp                        # GetItem
    Item::Union{Nothing,Item}
end

function json_make(::Type{ItemsResp}, x::LazyVal)
    items = Ref{Union{Nothing,Vector{Item}}}(nothing)
    last_key = Ref{Union{Nothing,Item}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "Items"
            jsontype(v) == JSON.JSONTypes.ARRAY || json_expected("array of items")
            out = Item[]
            p = JSON.applyarray(v) do i, val
                # distinct name: reusing `item` would capture (and box) the outer one
                it, q = json_make(Item, val)
                push!(out, it)
                return q
            end
            items[] = out
            return p::Int
        elseif k == "LastEvaluatedKey"
            item, p = json_make(Item, v); last_key[] = item; return p
        end
        return nothing
    end
    return ItemsResp(items[], last_key[]), pos::Int
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


## run submission (mirrors PkgEvalFarm.create_run: one PutItem + one expand message)

isodate() = Dates.format(Dates.now(UTC), dateformat"yyyy-mm-dd\THH:MM:SS\Z")

function new_run_id()
    suffix = join(rand("0123456789abcdef", 6))
    # a dateformat"" literal: `format` with a format *string* builds the DateFormat
    # dynamically, which `juliac --trim` cannot resolve
    Dates.format(Dates.now(UTC), dateformat"yyyymmdd-HHMMSS") * "-" * suffix
end

"Serialized `Configuration` the workers will reconstruct (modified settings only)."
function config_json(name::String, julia::String; assertions::Bool)
    flags = assertions ? "[\"LLVM_ASSERTIONS=1\",\"FORCE_ASSERTIONS=1\"]" : "[]"
    "{\"name\":$(JSON.json(name)),\"julia\":$(JSON.json(julia)),\"buildflags\":$flags}"
end

"""
    create_run(ctx; run_id, ...) -> created::Bool

Create the run (single conditional `PutItem`) and enqueue its expand message.
With a deterministic `run_id` (e.g. derived from the triggering comment id) the
conditional put doubles as an idempotency gate: `false` means this run was
already submitted by an earlier delivery of the same command. The expand message
is (re-)sent either way — duplicates are harmless by design, and skipping it
could strand a run whose first submission crashed between put and send.
"""
function create_run(ctx::LiteCtx; run_id::String=new_run_id(), configs_json::String,
                    packages::Vector{String}, context_json::String, submitter::String)
    item = Item(
        "run_id" => attr(run_id),
        "created_at" => attr(isodate()),
        "submitter" => attr(submitter),
        "status" => attr("expanding"),
        "configs" => attr(configs_json),
        "packages" => attr(JSON.json(packages)),
        "context" => attr(context_json),
        "total_jobs" => attr(0),
        "completed_jobs" => attr(0))
    payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
              "\"Item\":$(json_item(item))," *
              "\"ConditionExpression\":\"attribute_not_exists(run_id)\"}"
    created = try
        ddb(ctx, "PutItem", payload)
        true
    catch err
        is_conditional_failure(err) || rethrow()
        false
    end
    if !created
        # only rescue runs whose first submission crashed before the send; a
        # run already past expansion doesn't need (churn-y) extra messages
        str(get_run(ctx, run_id), "status") == "expanding" || return false
    end
    sqs_send_message(ctx, "{\"run_id\":$(JSON.json(run_id)),\"expand\":true}")
    return created
end


## polling GitHub for commands

# Secrets come from SSM SecureString parameters when *_PARAM names one (the
# Lambda: env vars there are readable by anyone with GetFunctionConfiguration
# and would sit in terraform state), or plain env otherwise (running `farm bot`
# on a box of your own). Cached: warm invocations and the poll loop must not
# re-read SSM every time, and IAM only allows the two known parameters anyway.
const SECRET_CACHE = Dict{String,String}()

function secret_from(ctx::LiteCtx, param_env::String, plain_env::String)
    param = get(ENV, param_env, "")::String
    isempty(param) && return get(ENV, plain_env, "")::String
    cached = get(SECRET_CACHE, param, "")::String
    isempty(cached) || return cached
    value = ssm_parameter(ctx, param)::String
    SECRET_CACHE[param] = value
    return value
end

function bot_gh(ctx::LiteCtx=ctx_from_env())
    token = secret_from(ctx, "BOT_TOKEN_PARAM", "BOT_GITHUB_TOKEN")
    isempty(token) && (token = get(ENV, "GITHUB_TOKEN", "")::String)
    isempty(token) &&
        error("set BOT_GITHUB_TOKEN (or BOT_TOKEN_PARAM) to the bot account's token")
    return GitHubCtx(token)
end

bot_name() = get(ENV, "BOT_NAME", "pkgeval")

function poll_mentions(ctx::LiteCtx, gh::GitHubCtx, name::String)
    resp = github_request(gh, "GET", "/notifications?participating=true")
    resp.status == 200 || error("failed to list notifications (HTTP $(resp.status))")
    for thread in parse_json(resp.body, Vector{Notification})
        thread.reason == "mention" || continue
        subject = thread.subject
        subject === nothing && continue
        subject.type in ("Issue", "PullRequest") || continue
        thread_id = thread.id
        thread_id === nothing && continue
        try
            handle_mention(ctx, gh, name, subject)
        catch err
            @error "failed to handle mention" msg=error_message(err)
        finally
            # mark read regardless: better to drop a command than to retry-spam a PR
            github_request(gh, "PATCH", "/notifications/threads/$thread_id")
        end
    end
end

function post_comment(gh::GitHubCtx, repo::String, number::Int, body::String)
    resp = github_request(gh, "POST", "/repos/$repo/issues/$number/comments";
                          body="{\"body\":$(JSON.json(body))}")
    resp.status == 201 || error("failed to post comment (HTTP $(resp.status))")
    return nothing
end

"Notifications-driven path: resolve the thread to a comment/issue, then run the command."
function handle_mention(ctx::LiteCtx, gh::GitHubCtx, name::String,
                        subject::NotificationSubject)
    comment_url = subject.latest_comment_url
    comment_url === nothing && return
    resp = github_request(gh, "GET", something(comment_url))
    resp.status == 200 || return
    comment = parse_json(resp.body, GhComment)
    comment_body = comment.body
    comment_body === nothing && return
    requester = comment.user === nothing ? "unknown" :
                something(something(comment.user).login, "unknown")

    issue_url = subject.url
    issue_url === nothing && return
    resp = github_request(gh, "GET", something(issue_url))
    resp.status == 200 || return
    issue = parse_json(resp.body, GhIssue)
    (issue.number === nothing || issue.repository_url === nothing) && return
    number = something(issue.number)
    repo = replace(something(issue.repository_url), gh.api_base * "/repos/" => "")
    pr_url = issue.pull_request === nothing ? nothing : something(issue.pull_request).url

    handle_command(ctx, gh, name, repo, number, something(comment_body), requester, pr_url;
                   comment_id=comment.id)
end

struct TeamMembership
    state::Union{Nothing,String}
end

function json_make(::Type{TeamMembership}, x::LazyVal)
    state = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "state"
            s, p = json_string(v); state[] = s; return p
        end
        return nothing
    end
    return TeamMembership(state[]), pos::Int
end

"""
Whether `login` may submit evaluation jobs. With `SUBMITTER_TEAM` set, that means
active membership in that team (the same gate the broker applies to human
submitters); with it empty, any `GITHUB_ORG` member qualifies (the policy classic
Nanosoldier documents — its actual author check was disabled in 2021, which this
bot deliberately does not replicate). The author's identity is attested by GitHub
(HMAC-verified webhook delivery, or comments fetched from the API), so this check
is what stops arbitrary passers-by from running their code on workers.
"""
function authorized_submitter(gh::GitHubCtx, login::String)
    org = get(ENV, "GITHUB_ORG", "")
    team = get(ENV, "SUBMITTER_TEAM", "")
    isempty(org) && error("bot misconfigured: GITHUB_ORG not set")
    if isempty(team)
        # org-membership mode; the bot's account must itself be an org member
        resp = github_request(gh, "GET", "/orgs/$org/members/$login")
        return resp.status == 204
    end
    resp = github_request(gh, "GET", "/orgs/$org/teams/$team/memberships/$login")
    resp.status == 200 || return false
    return parse_json(resp.body, TeamMembership).state == "active"
end

authz_description() = begin
    org = get(ENV, "GITHUB_ORG", "")
    team = get(ENV, "SUBMITTER_TEAM", "")
    isempty(team) ? "members of the $org organization" : "members of the $org/$team team"
end

"""
Execute a `runtests` command found in a comment (from either the webhook or the
notifications path): authorize the author, validate the command, resolve the PR,
submit the run, and acknowledge.
"""
function handle_command(ctx::LiteCtx, gh::GitHubCtx, name::String, repo::String,
                        number::Int, comment_body::String, requester::String,
                        pr_url::Union{Nothing,String};
                        comment_id::Union{Nothing,Int}=nothing)
    occursin("@$name", comment_body) || return
    command = parse_command(comment_body)
    command === nothing && return

    if !authorized_submitter(gh, requester)
        post_comment(gh, repo, number,
                     "Sorry @$requester, only $(authz_description()) may submit " *
                     "evaluation jobs.")
        return
    end

    if command.error !== nothing
        post_comment(gh, repo, number,
                     "Sorry @$requester, I couldn't parse that: $(something(command.error))")
        return
    end
    if pr_url === nothing
        post_comment(gh, repo, number, "`runtests` only works on pull requests.")
        return
    end

    resp = github_request(gh, "GET", something(pr_url))
    resp.status == 200 || error("failed to fetch PR (HTTP $(resp.status))")
    pr = parse_json(resp.body, GhPr)
    (pr.head === nothing || something(pr.head).sha === nothing) && error("PR without head sha")
    primary = "$repo#$(something(something(pr.head).sha))"
    against = if command.vs !== nothing
        resolve_vs(something(command.vs), repo)
    else
        base = pr.base === nothing ? nothing : something(pr.base).ref
        base === nothing && error("PR without base ref")
        "$repo#$(something(base))"
    end

    configs_json = "[" * config_json("primary", primary; assertions=true) * "," *
                         config_json("against", against; assertions=true) * "]"
    context_json = "{\"repo\":$(JSON.json(repo)),\"issue\":$number," *
                   "\"requester\":$(JSON.json(requester))}"
    # a comment-derived run id makes submission idempotent: webhook redelivery,
    # the fallback poll rediscovering the same mention, and webhook+poll overlap
    # all collapse into one run (kicking off a run is expensive)
    run_id = comment_id === nothing ? new_run_id() : "gh-$(something(comment_id))"
    created = create_run(ctx; run_id, configs_json, packages=command.packages,
                         context_json, submitter="$requester via @$name")
    if !created
        @info "command already processed; skipping duplicate delivery" run_id repo number
        return
    end
    post_comment(gh, repo, number, """
        Your package evaluation job has been submitted as run `$run_id` \
        (primary: `$primary`, against: `$against`). I will reply here once it finishes.""")
    @info "submitted run" run_id repo number
end


## finished runs -> reports

struct RunContext
    repo::Union{Nothing,String}
    issue::Union{Nothing,Int}
    requester::Union{Nothing,String}
end

function json_make(::Type{RunContext}, x::LazyVal)
    repo = Ref{Union{Nothing,String}}(nothing)
    issue = Ref{Union{Nothing,Int}}(nothing)
    requester = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "repo"
            s, p = json_string(v); repo[] = s; return p
        elseif k == "issue"
            n, p = json_int(v); issue[] = Int(n); return p
        elseif k == "requester"
            s, p = json_string(v); requester[] = s; return p
        end
        return nothing
    end
    return RunContext(repo[], issue[], requester[]), pos::Int
end

function check_finished_runs(ctx::LiteCtx, gh::GitHubCtx)
    start_key = ""
    while true
        payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
                  "\"FilterExpression\":\"#s = :done AND attribute_not_exists(reported)\"," *
                  "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
                  "\"ExpressionAttributeValues\":{\":done\":{\"S\":\"done\"}}" *
                  (isempty(start_key) ? "" : ",\"ExclusiveStartKey\":$start_key") * "}"
        resp = parse_json(ddb(ctx, "Scan", payload), ItemsResp)
        for run in something(resp.Items, Item[])
            report_finished_run(ctx, gh, run)
        end
        resp.LastEvaluatedKey === nothing && break
        start_key = json_item(something(resp.LastEvaluatedKey))
    end
end

function report_finished_run(ctx::LiteCtx, gh::GitHubCtx, run::Item)
    run_id = str(run, "run_id")

    # claim the reporting so concurrent invocations don't double-post
    payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
              "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
              "\"ConditionExpression\":\"attribute_not_exists(reported)\"," *
              "\"UpdateExpression\":\"SET reported = :t\"," *
              "\"ExpressionAttributeValues\":{\":t\":{\"BOOL\":true}}}"
    try
        ddb(ctx, "UpdateItem", payload)
    catch err
        # narrow before dispatching: a call on the Any-typed catch slot cannot be
        # resolved by the trim verifier
        err isa ErrorException && is_conditional_failure(err) && return
        rethrow()
    end

    report = generate_report(ctx, run_id; run)
    context = parse_json(str(run, "context", "{}"), RunContext)
    (context.repo === nothing || context.issue === nothing) && return
    mention = context.requester === nothing ? "" : "@$(something(context.requester)): "
    post_comment(gh, something(context.repo), something(context.issue), """
        $(mention)run `$run_id` finished — **$(report.summary)**

        Full report: $(report_url(ctx, run_id))""")
    @info "posted report" run_id
end


## report generation

report_key(run_id::String, name::String) = "runs/$run_id/report/$name"

s3_public_url(ctx::LiteCtx, key::String) =
    "https://$(ctx.bucket).s3.$(ctx.region).amazonaws.com/" *
    join(map(urlencode, split(key, '/')), '/')

report_url(ctx::LiteCtx, run_id::String) = s3_public_url(ctx, report_key(run_id, "report.md"))

issuccess(status::String) = status == "test" || status == "load"
const TERMINAL_STATUSES = ("test", "load", "fail", "crash", "kill", "skip", "error")

status_emoji(status::String) = issuccess(status) ? "✅" :
                               status == "fail"  ? "❌" :
                               status == "crash" ? "💥" :
                               status == "kill"  ? "⏰" :
                               status == "skip"  ? "⏭" : "❓"

function run_jobs(ctx::LiteCtx, run_id::String)
    jobs = Item[]
    start_key = ""
    while true
        payload = "{\"TableName\":$(JSON.json(ctx.jobs_table))," *
                  "\"KeyConditionExpression\":\"run_id = :run_id\"," *
                  "\"ExpressionAttributeValues\":{\":run_id\":{\"S\":$(JSON.json(run_id))}}" *
                  (isempty(start_key) ? "" : ",\"ExclusiveStartKey\":$start_key") * "}"
        resp = parse_json(ddb(ctx, "Query", payload), ItemsResp)
        append!(jobs, something(resp.Items, Item[]))
        resp.LastEvaluatedKey === nothing && break
        start_key = json_item(something(resp.LastEvaluatedKey))
    end
    return jobs
end

function get_run(ctx::LiteCtx, run_id::String)
    payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
              "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}}"
    resp = parse_json(ddb(ctx, "GetItem", payload), ItemResp)
    resp.Item === nothing && error("no such run: $run_id")
    return something(resp.Item)
end

struct ConfigInfo
    name::Union{Nothing,String}
    julia::Union{Nothing,String}
    buildflags::Union{Nothing,Vector{String}}
end

function json_make(::Type{ConfigInfo}, x::LazyVal)
    name = Ref{Union{Nothing,String}}(nothing)
    julia = Ref{Union{Nothing,String}}(nothing)
    buildflags = Ref{Union{Nothing,Vector{String}}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "name"
            s, p = json_string(v); name[] = s; return p
        elseif k == "julia"
            s, p = json_string(v); julia[] = s; return p
        elseif k == "buildflags"
            f, p = json_string_vector(v); buildflags[] = f; return p
        end
        return nothing
    end
    return ConfigInfo(name[], julia[], buildflags[]), pos::Int
end

function json_make(::Type{Vector{ConfigInfo}}, x::LazyVal)
    jsontype(x) == JSON.JSONTypes.ARRAY || json_expected("array")
    out = ConfigInfo[]
    pos = JSON.applyarray(x) do i, v
        c, p = json_make(ConfigInfo, v)
        push!(out, c)
        return p
    end
    return out, pos::Int
end

function describe_job(ctx::LiteCtx, job::Item)
    version = opt_str(job, "version")
    status = str(job, "status")
    reason_msg = str(job, "reason_message", "")
    log_key = opt_str(job, "log_key")
    log = log_key === nothing ? "no log" : "[log]($(s3_public_url(ctx, something(log_key))))"
    string("**", str(job, "package"), "**",
           version === nothing ? "" : " v$(something(version))",
           ": $(status_emoji(status)) $status",
           isempty(reason_msg) ? "" : " ($reason_msg)",
           " — ", log)
end

"""
    generate_report(ctx, run_id) -> (; summary, markdown)

Aggregate all job results into a markdown comparison report + `db.json`, uploaded to
`runs/<run_id>/report/` in S3.
"""
function generate_report(ctx::LiteCtx, run_id::String; run::Item=get_run(ctx, run_id))
    jobs = run_jobs(ctx, run_id)
    configs = parse_json(str(run, "configs"), Vector{ConfigInfo})

    io = IOBuffer()
    println(io, "# PkgEval report — run `$run_id`\n")
    for c in configs
        print(io, "- **", something(c.name, "?"), "**: `julia = ", something(c.julia, "nightly"), "`")
        flags = c.buildflags
        (flags === nothing || isempty(something(flags))) ||
            print(io, ", `buildflags = ", join(something(flags), " "), "`")
        println(io)
    end
    ndone = count(j -> str(j, "status") in TERMINAL_STATUSES, jobs)
    println(io, "- jobs: $ndone/$(length(jobs)) finished, submitted by ",
            str(run, "submitter", "?"), " at ", str(run, "created_at", "?"), "\n")

    config_names = String[something(c.name, "?") for c in configs]
    summary = ""
    if length(config_names) == 2
        by_pkg = Dict{String,Dict{String,Item}}()
        for job in jobs
            get!(by_pkg, str(job, "package"), Dict{String,Item}())[str(job, "config")] = job
        end
        new_failures = String[]
        now_passing = String[]
        still_failing = String[]
        for pkg in sort!(collect(keys(by_pkg)))
            group = by_pkg[pkg]
            (haskey(group, config_names[1]) && haskey(group, config_names[2])) || continue
            p, a = group[config_names[1]], group[config_names[2]]
            pst, ast = str(p, "status"), str(a, "status")
            (pst in TERMINAL_STATUSES && ast in TERMINAL_STATUSES) || continue
            if !issuccess(pst) && issuccess(ast) && pst != "skip"
                push!(new_failures, "- " * describe_job(ctx, p) *
                      " (vs. $(status_emoji(ast)))")
            elseif issuccess(pst) && !issuccess(ast) && ast != "skip"
                push!(now_passing, "- " * describe_job(ctx, p))
            elseif !issuccess(pst) && !issuccess(ast) && pst != "skip"
                push!(still_failing, "- " * describe_job(ctx, p))
            end
        end
        summary = isempty(new_failures) ? "no new package failures ✅" :
                  "possible new issues: $(length(new_failures)) package$(length(new_failures) == 1 ? "" : "s") ❌"
        println(io, "**", summary, "**\n")
        for (title, entries, open) in (
                ("❌ Packages that failed on primary but not on against", new_failures, true),
                ("✅ Packages that now pass", now_passing, false),
                ("💔 Packages that failed on both", still_failing, false))
            isempty(entries) && continue
            println(io, "<details", open ? " open" : "", "><summary>$title ($(length(entries)))</summary>\n")
            for e in entries
                println(io, e)
            end
            println(io, "\n</details>\n")
        end
    else
        npass = count(j -> issuccess(str(j, "status")), jobs)
        nfail = count(j -> str(j, "status") in ("fail", "crash", "kill", "error"), jobs)
        summary = "$npass passed, $nfail failed"
        println(io, "**", summary, "**\n")
        for status in TERMINAL_STATUSES
            issuccess(status) && continue
            entries = String["- " * describe_job(ctx, job)
                             for job in jobs if str(job, "status") == status]
            isempty(entries) && continue
            println(io, "<details><summary>$(status_emoji(status)) $status ($(length(entries)))</summary>\n")
            for e in entries
                println(io, e)
            end
            println(io, "\n</details>\n")
        end
    end
    markdown = String(take!(io))

    s3_put(ctx, report_key(run_id, "report.md"), markdown;
           content_type="text/markdown; charset=utf-8")
    s3_put(ctx, report_key(run_id, "db.json"), db_json(run, jobs);
           content_type="application/json")
    return (; summary, markdown)
end

# machine-readable dump of the run + job records (attribute values unwrapped)
function db_json(run::Item, jobs::Vector{Item})
    io = IOBuffer()
    print(io, "{\"run\":")
    item_json_plain(io, run)
    print(io, ",\"jobs\":[")
    for (i, job) in enumerate(jobs)
        i == 1 || print(io, ",")
        item_json_plain(io, job)
    end
    print(io, "]}")
    return String(take!(io))
end

function item_json_plain(io::IO, item::Item)
    print(io, "{")
    first_entry = true
    for k in sort!(collect(keys(item)))
        a = item[k]
        first_entry || print(io, ",")
        first_entry = false
        print(io, JSON.json(k), ":")
        if a.S !== nothing
            print(io, JSON.json(something(a.S)))
        elseif a.N !== nothing
            print(io, something(a.N))
        elseif a.BOOL !== nothing
            print(io, something(a.BOOL))
        else
            print(io, "null")
        end
    end
    print(io, "}")
end


## entry points

"One poll iteration: handle new commands, report finished runs."
function handle_invocation(ctx::LiteCtx=ctx_from_env(), gh::GitHubCtx=bot_gh())
    name = bot_name()
    poll_mentions(ctx, gh, name)
    check_finished_runs(ctx, gh)
    return nothing
end

"""
    run_bot(ctx_provider=ctx_from_env, gh=bot_gh(); interval=60)

Interactive polling loop (`farm bot`); the Lambda uses `lambda_main` instead.
`ctx_provider` is called every iteration so brokered credentials can refresh.
"""
function run_bot(ctx_provider=ctx_from_env, gh::GitHubCtx=bot_gh();
                 interval::Int=60, once::Bool=false)
    @info "bot started" name=bot_name()
    while true
        try
            handle_invocation(ctx_provider(), gh)
        catch err
            err isa InterruptException && break
            @error "bot iteration failed" msg=error_message(err)
        end
        once && break
        sleep(interval)
    end
end

## Lambda event dispatch
#
# One Lambda, three triggers:
#   - Function URL: GitHub `issue_comment` webhooks (HMAC-verified) -> handle_command
#   - DynamoDB stream on the runs table (filtered to status = "done") -> post report
#   - EventBridge schedule (infrequent fallback) -> full notifications poll
#
# The webhook payload carries the comment/issue/repo inline, so the webhook path
# costs a single GitHub call (the PR fetch) instead of the notifications dance.

struct GhRepoFull
    full_name::Union{Nothing,String}
end

"GitHub `issue_comment` webhook payload (the parts we use)."
struct WebhookPayload
    action::Union{Nothing,String}
    comment::Union{Nothing,GhComment}
    issue::Union{Nothing,GhIssue}
    repository::Union{Nothing,GhRepoFull}
end

"One Lambda invocation event, whatever its trigger (fields absent when N/A)."
struct TopEvent
    new_images::Vector{Item}            # DynamoDB stream records (runs items)
    method::Union{Nothing,String}       # Function URL fields
    signature::Union{Nothing,String}    # x-hub-signature-256
    ghevent::Union{Nothing,String}      # x-github-event
    body::Union{Nothing,String}
    is_base64::Bool
end

function json_make(::Type{GhRepoFull}, x::LazyVal)
    full_name = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "full_name"
            s, p = json_string(v); full_name[] = s; return p
        end
        return nothing
    end
    return GhRepoFull(full_name[]), pos::Int
end

function json_make(::Type{WebhookPayload}, x::LazyVal)
    action = Ref{Union{Nothing,String}}(nothing)
    comment = Ref{Union{Nothing,GhComment}}(nothing)
    issue = Ref{Union{Nothing,GhIssue}}(nothing)
    repository = Ref{Union{Nothing,GhRepoFull}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "action"
            s, p = json_string(v); action[] = s; return p
        elseif k == "comment"
            c, p = json_make(GhComment, v); comment[] = c; return p
        elseif k == "issue"
            i, p = json_make(GhIssue, v); issue[] = i; return p
        elseif k == "repository"
            r, p = json_make(GhRepoFull, v); repository[] = r; return p
        end
        return nothing
    end
    return WebhookPayload(action[], comment[], issue[], repository[]), pos::Int
end

function json_make(::Type{TopEvent}, x::LazyVal)
    new_images = Item[]
    method = Ref{Union{Nothing,String}}(nothing)
    signature = Ref{Union{Nothing,String}}(nothing)
    ghevent = Ref{Union{Nothing,String}}(nothing)
    body = Ref{Union{Nothing,String}}(nothing)
    is_base64 = Ref(false)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        # NB: locals in the nested closures carry unique names — reusing an outer
        # closure's variable names (`s`, `p`, ...) would make Julia treat them as
        # shared (boxed) captures, which the trim verifier rejects as `Any`
        if k == "Records"
            return JSON.applyarray(v) do i, record
                jsontype(record) == JSON.JSONTypes.OBJECT || json_expected("stream record")
                JSON.applyobject(record) do rk, rv
                    isnullval(rv) && return nothing
                    rk == "dynamodb" || return nothing
                    JSON.applyobject(rv) do dk, dv
                        isnullval(dv) && return nothing
                        dk == "NewImage" || return nothing
                        image, image_pos = json_make(Item, dv)
                        push!(new_images, image)
                        return image_pos
                    end
                end
            end
        elseif k == "requestContext"
            return JSON.applyobject(v) do rk, rv
                rk == "http" || return nothing
                JSON.applyobject(rv) do hk, hv
                    if hk == "method"
                        mstr, mpos = json_string(hv); method[] = mstr; return mpos
                    end
                    return nothing
                end
            end
        elseif k == "headers"
            return JSON.applyobject(v) do hk, hv
                isnullval(hv) && return nothing
                header = lowercase(convert(String, hk)::String)  # hk is a lazy PtrString
                if header == "x-hub-signature-256"
                    hstr, hpos = json_string(hv); signature[] = hstr; return hpos
                elseif header == "x-github-event"
                    hstr, hpos = json_string(hv); ghevent[] = hstr; return hpos
                end
                return nothing
            end
        elseif k == "body"
            s, p = json_string(v); body[] = s; return p
        elseif k == "isBase64Encoded"
            b, p = json_bool(v); is_base64[] = b; return p
        end
        return nothing
    end
    return TopEvent(new_images, method[], signature[], ghevent[], body[], is_base64[]),
           pos::Int
end

fnurl_response(status::Int, payload::String) =
    "{\"statusCode\":$status,\"headers\":{\"Content-Type\":\"application/json\"}," *
    "\"body\":$(JSON.json(payload))}"

"Handle a verified GitHub webhook delivery."
function handle_webhook(ctx::LiteCtx, gh::GitHubCtx, event::TopEvent)
    secret = secret_from(ctx, "WEBHOOK_SECRET_PARAM", "GITHUB_WEBHOOK_SECRET")
    raw = something(event.body, "")
    event.is_base64 && (raw = String(FarmLite.base64decode_lite(raw)))
    if !FarmLite.valid_signature(secret, raw, event.signature)
        return fnurl_response(401, "{\"error\":\"invalid signature\"}")
    end
    # ping etc. are accepted but ignored
    event.ghevent == "issue_comment" ||
        return fnurl_response(200, "{\"ignored\":true}")

    payload = parse_json(raw, WebhookPayload)
    (payload.action == "created" && payload.comment !== nothing &&
     payload.issue !== nothing && payload.repository !== nothing) ||
        return fnurl_response(200, "{\"ignored\":true}")
    comment = something(payload.comment)
    issue = something(payload.issue)
    repo = something(payload.repository).full_name
    (comment.body === nothing || issue.number === nothing || repo === nothing) &&
        return fnurl_response(200, "{\"ignored\":true}")
    requester = comment.user === nothing ? "unknown" :
                something(something(comment.user).login, "unknown")
    pr_url = issue.pull_request === nothing ? nothing : something(issue.pull_request).url

    handle_command(ctx, gh, bot_name(), something(repo), something(issue.number),
                   something(comment.body), requester, pr_url; comment_id=comment.id)
    return fnurl_response(200, "{\"ok\":true}")
end

"""
    handle_event(event_body::String, ctx=ctx_from_env(), gh=bot_gh()) -> String

Dispatch one Lambda invocation: webhook delivery, DynamoDB stream batch, or the
scheduled fallback poll. Returns the response JSON.
"""
function handle_event(event_body::String, ctx::LiteCtx=ctx_from_env(),
                      gh::GitHubCtx=bot_gh())
    event = parse_json(event_body, TopEvent)
    if !isempty(event.new_images)
        # runs that just flipped to done (event source mapping filters on status)
        for run in event.new_images
            str(run, "status", "") == "done" || continue
            report_finished_run(ctx, gh, run)
        end
        return "{\"ok\":true}"
    elseif event.method !== nothing
        return handle_webhook(ctx, gh, event)
    else
        # scheduled fallback: full poll (also catches missed webhook/stream events)
        handle_invocation(ctx, gh)
        return "{\"ok\":true}"
    end
end

"Lambda entry."
function lambda_main()
    lambda_loop(handle_event)
end

end # module
