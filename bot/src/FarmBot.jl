"""
The @pkgeval bot: turns GitHub PR comments (`@pkgeval runtests(...)`) into
farm runs, keeps its submission comment updated with hourly progress + ETA,
and edits the final report into that same comment when the run finishes.

Deployed as a juliac-compiled Lambda invoked on an EventBridge schedule; each
invocation performs one poll (mentions + finished runs + progress edits). It
carries the submitter IAM
policy on its execution role, so unlike human submitters it needs neither the broker
nor GitHub team membership — only its GitHub account token, read from the SSM
parameter named by `BOT_TOKEN_PARAM` (or, outside Lambda, from `BOT_GITHUB_TOKEN`).

All state lives in the runs table and GitHub, so the bot is also runnable anywhere
else (`farm bot` runs the same code in a polling loop).
"""
module FarmBot

using Dates
import Downloads  # @trim_errmsg escapes into this module and names Downloads.RequestError
using JSON

include(joinpath(@__DIR__, "..", "..", "lite", "src", "FarmLite.jl"))
using .FarmLite
using .FarmLite: Attr, Item, attr, str, int, flt, opt_str, json_item, ddb, sqs_send_message,
                 s3_put, is_conditional_failure, GitHubCtx, github_request, urlencode,
                 error_message, lambda_loop, ctx_from_env, ssm_parameter, parse_isodate,
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
    fresh_baseline::Bool
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
    runtests(fresh_baseline = true)
                                  re-evaluate the baseline even when results
                                  from an identical earlier run exist (use when
                                  the baseline looks flaky)

The argument expression is parsed, never evaluated.
"""
function parse_command(body::AbstractString)
    m = match(BOT_COMMAND, body)
    m === nothing && return nothing
    packages = String[]
    vs = nothing
    fresh_baseline = false
    args = strip(something(m.captures[2]))
    if !isempty(args)
        expr = try
            Meta.parse("runtests($args)")
        catch
            return Command(packages, vs, fresh_baseline, "could not parse command arguments")
        end
        Meta.isexpr(expr, :call) || return Command(packages, vs, fresh_baseline, "could not parse command arguments")
        for arg in (expr::Expr).args[2:end]
            if (Meta.isexpr(arg, :kw) || Meta.isexpr(arg, :(=))) &&
               (arg::Expr).args[1] === :vs && (arg::Expr).args[2] isa String
                vs = (arg::Expr).args[2]::String
            elseif (Meta.isexpr(arg, :kw) || Meta.isexpr(arg, :(=))) &&
                   (arg::Expr).args[1] === :fresh_baseline && (arg::Expr).args[2] isa Bool
                fresh_baseline = (arg::Expr).args[2]::Bool
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
                return Command(packages, vs, fresh_baseline, "unsupported argument `$argdesc`")
            end
        end
    end
    return Command(packages, vs, fresh_baseline, nothing)
end

"Resolve a `vs` spec against the repo the PR targets."
function resolve_vs(vs::AbstractString, repo::AbstractString)
    startswith(vs, ":") && return "$repo#$(chop(vs; head=1, tail=0))"
    startswith(vs, "@") && return "$repo#$(chop(vs; head=1, tail=0))"
    # bare "#ref" / version specs: anchor to the repo so pin_commit can resolve
    # them to a sha. The farm always builds with assertions, and those builds
    # are keyed by repo+sha — an unanchored "#1.12.6" would dead-end on the
    # worker (no official assert binaries to download, no sha to request).
    startswith(vs, "#") && return "$repo$vs"
    occursin(r"^v?\d+(\.\d+)+$", vs) && return "$repo#$vs"
    return String(vs)
end

"""
Pin a `repo#ref` spec to the exact commit the ref names right now. Two reasons:
every worker then evaluates the same Julia even if the branch moves mid-run,
and baseline reuse (expand_run) only matches immutable specs, so an unpinned
`#master` baseline could never be reused. Non-repo specs (`nightly`) and
already-pinned shas pass through; so does anything the API cannot resolve —
the workers' own resolution is the fallback, as before. Version refs try the
tag's "v" spelling too, so `vs = "#1.12.6"` pins to the v1.12.6 tag commit.
"""
function pin_commit(gh::GitHubCtx, spec::String)
    m = match(r"^([^#]+)#(.+)$", spec)
    m === nothing && return spec
    repo, ref = String(something(m.captures[1])), String(something(m.captures[2]))
    occursin(r"^[0-9a-f]{40}$", ref) && return spec
    # bare version numbers name release tags, which carry a "v" prefix in the
    # julia repo ("1.12.6" -> tag "v1.12.6"); try both spellings
    candidates = occursin(r"^\d+(\.\d+)+$", ref) ? [ref, "v" * ref] : [ref]
    for candidate in candidates
        resp = github_request(gh, "GET", "/repos/$repo/commits/$(urlencode(candidate))")
        resp.status == 200 || continue
        sha = parse_json(resp.body, GhCommit).sha
        sha === nothing && continue
        return "$repo#$(something(sha))"
    end
    return spec
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

isodate(t::DateTime=Dates.now(UTC)) = Dates.format(t, dateformat"yyyy-mm-dd\THH:MM:SS\Z")

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
                    packages::Vector{String}, context_json::String, submitter::String,
                    reuse::Bool=true)
    item = Item(
        "run_id" => attr(run_id),
        "created_at" => attr(isodate()),
        "submitter" => attr(submitter),
        "status" => attr("expanding"),
        "configs" => attr(configs_json),
        "packages" => attr(JSON.json(packages)),
        "context" => attr(context_json),
        "total_jobs" => attr(0),
        "completed_jobs" => attr(0),
        "reuse" => attr(reuse))
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
    sqs_send_message(ctx, "{\"run_id\":$(JSON.json(run_id)),\"expand\":true}";
                     queue_url=FarmLite.slow_queue(ctx))
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

"Post a new issue comment; returns its id (`nothing` if the response lacked one)."
function post_comment(gh::GitHubCtx, repo::String, number::Int, body::String)
    resp = github_request(gh, "POST", "/repos/$repo/issues/$number/comments";
                          body="{\"body\":$(JSON.json(body))}")
    resp.status == 201 || error("failed to post comment (HTTP $(resp.status))")
    return parse_json(resp.body, GhComment).id
end

function update_comment(gh::GitHubCtx, repo::String, comment_id::Int, body::String)
    resp = github_request(gh, "PATCH", "/repos/$repo/issues/comments/$comment_id";
                          body="{\"body\":$(JSON.json(body))}")
    resp.status == 200 || error("failed to update comment (HTTP $(resp.status))")
    return nothing
end

function delete_comment(gh::GitHubCtx, repo::String, comment_id::Int)
    resp = github_request(gh, "DELETE", "/repos/$repo/issues/comments/$comment_id")
    resp.status == 204 || error("failed to delete comment (HTTP $(resp.status))")
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

"The submitter gate: (org, team), where an empty team means plain org membership. A `SUBMITTER_TEAM` of \"ORG/TEAM\" carries its own org (matching the broker's spec format)."
function submitter_requirement()
    org = get(ENV, "GITHUB_ORG", "")
    team = get(ENV, "SUBMITTER_TEAM", "")
    isempty(org) && error("bot misconfigured: GITHUB_ORG not set")
    i = findfirst('/', team)
    if i !== nothing
        org = team[1:prevind(team, i)]
        team = team[nextind(team, i):end]
    end
    return (org, team)
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
    org, team = submitter_requirement()
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
    org, team = submitter_requirement()
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
    # pin branches to the commit they name right now: consistent across workers,
    # and immutable specs are what makes baseline reuse possible at all
    against = pin_commit(gh, against)

    configs_json = "[" * config_json("primary", primary; assertions=true) * "," *
                         config_json("against", against; assertions=true) * "]"
    context_json = "{\"repo\":$(JSON.json(repo)),\"issue\":$number," *
                   "\"requester\":$(JSON.json(requester))" *
                   (comment_id === nothing ? "" :
                    ",\"comment\":$(something(comment_id))") * "}"
    # a comment-derived run id makes submission idempotent: webhook redelivery,
    # the fallback poll rediscovering the same mention, and webhook+poll overlap
    # all collapse into one run (kicking off a run is expensive)
    run_id = comment_id === nothing ? new_run_id() : "gh-$(something(comment_id))"
    created = create_run(ctx; run_id, configs_json, packages=command.packages,
                         context_json, submitter="$requester via @$name",
                         reuse=!command.fresh_baseline)
    if !created
        @info "command already processed; skipping duplicate delivery" run_id repo number
        return
    end
    comment_id = post_comment(gh, repo, number, """
        Your package evaluation job has been submitted as run `$run_id` \
        (primary: `$primary`, against: `$against`). I will keep this comment \
        updated with progress, and post the report as a new comment when it \
        finishes.""")
    if comment_id !== nothing
        try
            record_comment_id(ctx, run_id, something(comment_id))
        catch err
            # non-fatal: the run just gets old-style separate comments
            @error "failed to record comment id" run_id msg=error_message(err)
        end
    end
    @info "submitted run" run_id repo number
end

"Remember the submission comment's id so progress and final updates can edit it."
function record_comment_id(ctx::LiteCtx, run_id::String, comment_id::Int)
    payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
              "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
              "\"UpdateExpression\":\"SET comment_id = :c\"," *
              "\"ExpressionAttributeValues\":{\":c\":{\"N\":\"$comment_id\"}}}"
    ddb(ctx, "UpdateItem", payload)
    return nothing
end


## finished runs -> reports

struct RunContext
    repo::Union{Nothing,String}
    issue::Union{Nothing,Int}
    requester::Union{Nothing,String}
    comment::Union{Nothing,Int}   # the triggering comment, when one exists
end

function json_make(::Type{RunContext}, x::LazyVal)
    repo = Ref{Union{Nothing,String}}(nothing)
    issue = Ref{Union{Nothing,Int}}(nothing)
    requester = Ref{Union{Nothing,String}}(nothing)
    comment = Ref{Union{Nothing,Int}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "repo"
            s, p = json_string(v); repo[] = s; return p
        elseif k == "issue"
            n, p = json_int(v); issue[] = Int(n); return p
        elseif k == "requester"
            s, p = json_string(v); requester[] = s; return p
        elseif k == "comment"
            n, p = json_int(v); comment[] = Int(n); return p
        end
        return nothing
    end
    return RunContext(repo[], issue[], requester[], comment[]), pos::Int
end

"""
The link a run's trigger label points at: the comment that started the run
when the context recorded one, the PR otherwise.
"""
trigger_link(repo::String, issue::Int, comment::Union{Nothing,Int}) =
    "https://github.com/$repo/pull/$issue" *
    (comment === nothing ? "" : "#issuecomment-$(something(comment))")

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

## the jobs-DLQ consumer: dead messages close out their jobs/runs

struct DeadRef
    run_id::Union{Nothing,String}
    config::Union{Nothing,String}
    package::Union{Nothing,String}
    expand::Bool
end

function json_make(::Type{DeadRef}, x::LazyVal)
    drun = Ref{Union{Nothing,String}}(nothing)
    dcfg = Ref{Union{Nothing,String}}(nothing)
    dpkg = Ref{Union{Nothing,String}}(nothing)
    dexp = Ref(false)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "run_id"
            dstr, dpos = json_string(v); drun[] = dstr; return dpos
        elseif k == "config"
            cstr, cpos = json_string(v); dcfg[] = cstr; return cpos
        elseif k == "package"
            pstr, ppos = json_string(v); dpkg[] = pstr; return ppos
        elseif k == "expand"
            bval, bpos = FarmLite.json_bool(v); dexp[] = bval; return bpos
        end
        return nothing
    end
    return DeadRef(drun[], dcfg[], dpkg[], dexp[]), pos::Int
end

struct AttrResp                        # UpdateItem with ReturnValues
    Attributes::Union{Nothing,Item}
end

function json_make(::Type{AttrResp}, x::LazyVal)
    attrs = Ref{Union{Nothing,Item}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        k == "Attributes" || return nothing
        aitem, apos = json_make(Item, v)
        attrs[] = aitem
        return apos
    end
    return AttrResp(attrs[]), pos::Int
end

function handle_dead_messages(ctx::LiteCtx, gh::GitHubCtx, bodies::Vector{String})
    for raw in bodies
        try
            handle_dead_message(ctx, gh, raw)
        catch err
            # best effort by design: an unprocessable dead message must not
            # wedge the batch (there is no DLQ behind the DLQ)
            dmsg = (FarmLite.@trim_errmsg err)::String
            println(Core.stderr, "failed to process dead message: " * dmsg)
        end
    end
end

function handle_dead_message(ctx::LiteCtx, gh::GitHubCtx, raw::String)
    ref = parse_json(raw, DeadRef)
    ref.run_id === nothing && return
    run_id = something(ref.run_id)
    # A message that died *because its Julia build is still being made* is not
    # dead — the queue's receive budget is just shorter than a CI build. While
    # the build is legitimately pending, re-enqueue the original message (a
    # fresh message, so a fresh budget): the DLQ recycles instead of burying.
    if waiting_on_build(ctx, ref)
        sqs_send_message(ctx, raw;
                         queue_url=ref.expand ? FarmLite.slow_queue(ctx) : ctx.queue_url)
        @info "recycled dead message: its Julia build is still pending" run_id
        return nothing
    end
    if ref.expand
        # the run can never expand; fail it and tell the submitter
        mark_run_failed(ctx, gh, run_id,
                        "its package set could not be expanded (the expand message was dead-lettered)")
    elseif ref.config !== nothing && ref.package !== nothing
        dead_job(ctx, gh, run_id, something(ref.config), something(ref.package))
    end
    return nothing
end

"Record a dead-lettered job as an error result and complete the run if it was last."
function dead_job(ctx::LiteCtx, gh::GitHubCtx, run_id::String, config::String, package::String)
    job_key = string(config, "#", package)
    # only jobs that never finished: a duplicate delivery of a completed job
    # can also die here, and must not double-count
    payload = "{\"TableName\":$(JSON.json(ctx.jobs_table))," *
              "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}," *
              "\"job_key\":{\"S\":$(JSON.json(job_key))}}," *
              "\"ConditionExpression\":\"attribute_exists(run_id) AND #s IN (:p, :r)\"," *
              "\"UpdateExpression\":\"SET #s = :e, reason = :why, reason_message = :rm, finished_at = :now\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{" *
              "\":p\":{\"S\":\"pending\"},\":r\":{\"S\":\"running\"}," *
              "\":e\":{\"S\":\"error\"},\":why\":{\"S\":\"undeliverable\"}," *
              "\":rm\":{\"S\":\"the job could not be delivered to any worker\"}," *
              "\":now\":{\"S\":$(JSON.json(isodate()))}}}"
    try
        ddb(ctx, "UpdateItem", payload)
    catch err
        err isa ErrorException && is_conditional_failure(err) && return
        rethrow()
    end
    @info "dead-lettered job recorded as error" run_id job_key

    bump = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
           "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
           "\"UpdateExpression\":\"ADD completed_jobs :one\"," *
           "\"ExpressionAttributeValues\":{\":one\":{\"N\":\"1\"}}," *
           "\"ReturnValues\":\"ALL_NEW\"}"
    resp = parse_json(ddb(ctx, "UpdateItem", bump), AttrResp)
    resp.Attributes === nothing && return
    run = something(resp.Attributes)
    if haskey(run, "completed_jobs") && haskey(run, "total_jobs") &&
       int(run, "completed_jobs") >= int(run, "total_jobs") &&
       str(run, "status", "") == "active"
        flip = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
               "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
               "\"ConditionExpression\":\"#s = :active AND completed_jobs >= total_jobs\"," *
               "\"UpdateExpression\":\"SET #s = :done, finished_at = :now\"," *
               "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
               "\"ExpressionAttributeValues\":{\":active\":{\"S\":\"active\"}," *
               "\":done\":{\"S\":\"done\"},\":now\":{\"S\":$(JSON.json(isodate()))}}}"
        try
            ddb(ctx, "UpdateItem", flip)
        catch err
            err isa ErrorException && is_conditional_failure(err) && return
            rethrow()
        end
        # the stream's "done" filter now fires and posts the report as usual
        @info "run completed via dead-letter accounting" run_id
    end
    return nothing
end

"""
Flip `active` runs whose every job is already terminal to `done`. The workers'
transactional accounting makes a lost counter increment rare, but a worker (or
this Lambda's DLQ path) dying between the final increment and the status flip
still strands a finished run in `active` forever — this scheduled sweep is the
backstop that heals it (the flip fires the stream, which posts the report).
"""
function reconcile_stuck_runs(ctx::LiteCtx)
    start_key = ""
    while true
        payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
                  "\"FilterExpression\":\"#s = :active AND completed_jobs >= total_jobs\"," *
                  "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
                  "\"ExpressionAttributeValues\":{\":active\":{\"S\":\"active\"}}" *
                  (isempty(start_key) ? "" : ",\"ExclusiveStartKey\":$start_key") * "}"
        resp = parse_json(ddb(ctx, "Scan", payload), ItemsResp)
        for run in something(resp.Items, Item[])
            run_id = str(run, "run_id")
            flip = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
                   "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
                   "\"ConditionExpression\":\"#s = :active AND completed_jobs >= total_jobs\"," *
                   "\"UpdateExpression\":\"SET #s = :done, finished_at = :now\"," *
                   "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
                   "\"ExpressionAttributeValues\":{\":active\":{\"S\":\"active\"}," *
                   "\":done\":{\"S\":\"done\"},\":now\":{\"S\":$(JSON.json(isodate()))}}}"
            try
                ddb(ctx, "UpdateItem", flip)
            catch err
                err isa ErrorException && is_conditional_failure(err) && continue
                rethrow()
            end
            @info "reconciled stuck run to done" run_id
        end
        resp.LastEvaluatedKey === nothing && break
        start_key = json_item(something(resp.LastEvaluatedKey))
    end
    return nothing
end

"Mark a run failed (from any non-terminal state) and tell its submitter."
function mark_run_failed(ctx::LiteCtx, gh::GitHubCtx, run_id::String, why::String)
    # `reported` is claimed in the same write: this path posts the notification
    # itself, and check_failed_runs must not report the run a second time
    payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
              "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
              "\"ConditionExpression\":\"#s IN (:expanding, :active)\"," *
              "\"UpdateExpression\":\"SET #s = :failed, finished_at = :now, " *
              "reported = :t, failure_reason = :why\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{\":expanding\":{\"S\":\"expanding\"}," *
              "\":active\":{\"S\":\"active\"},\":failed\":{\"S\":\"failed\"}," *
              "\":t\":{\"BOOL\":true},\":why\":{\"S\":$(JSON.json(why))}," *
              "\":now\":{\"S\":$(JSON.json(isodate()))}}}"
    try
        ddb(ctx, "UpdateItem", payload)
    catch err
        err isa ErrorException && is_conditional_failure(err) && return
        rethrow()
    end
    @info "run marked failed" run_id why
    # the stream filter only fires on "done", so failure is reported here
    run = get_run(ctx, run_id)
    context = parse_json(str(run, "context", "{}"), RunContext)
    (context.repo === nothing || context.issue === nothing) && return
    mention = context.requester === nothing ? "" : "@$(something(context.requester)): "
    deliver_final(gh, something(context.repo), something(context.issue), run,
                  mention * "run `" * run_id * "` **failed** — " * why * ".")
    return nothing
end

"""
Deliver a run's final message as a *new* comment, then delete the status
comment when one was recorded. Editing the status comment in place kept
threads tidy but sent no email — GitHub only notifies on new comments — so
the final word arrives fresh and the superseded status body is removed
(best-effort: a failed delete leaves a stale status comment behind, never
blocks delivery).
"""
function deliver_final(gh::GitHubCtx, repo::String, issue::Int, run::Item, body::String)
    post_comment(gh, repo, issue, body)
    comment_id = int(run, "comment_id", 0)
    if comment_id > 0
        try
            delete_comment(gh, repo, comment_id)
        catch err
            @error "deleting the status comment failed" comment_id msg=error_message(err)
        end
    end
    return nothing
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
    costline = report.cost <= 0 ? "" :
        report.cost_partial ?
        "\nCompute cost: at least " * dollars(report.cost) * " (EC2 spot; partially metered)" :
        "\nEstimated compute cost: " * dollars(report.cost) * " (EC2 spot)"
    deliver_final(gh, something(context.repo), something(context.issue), run, """
        $(mention)run `$run_id` finished — **$(report.summary)**

        Full report: $(report_url(ctx, run_id))$(costline)""")
    @info "posted report" run_id
end

"""
Report runs a *worker* failed (`status = "failed"` without `reported`): the
worker can only write the reason into the table (e.g. "its Julia build
failed"), so the notification is posted from here. DLQ-driven failures set
`reported` inside mark_run_failed and never reach this scan.
"""
function check_failed_runs(ctx::LiteCtx, gh::GitHubCtx)
    start_key = ""
    while true
        payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
                  "\"FilterExpression\":\"#s = :failed AND attribute_not_exists(reported)\"," *
                  "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
                  "\"ExpressionAttributeValues\":{\":failed\":{\"S\":\"failed\"}}" *
                  (isempty(start_key) ? "" : ",\"ExclusiveStartKey\":$start_key") * "}"
        resp = parse_json(ddb(ctx, "Scan", payload), ItemsResp)
        for run in something(resp.Items, Item[])
            report_failed_run(ctx, gh, run)
        end
        resp.LastEvaluatedKey === nothing && break
        start_key = json_item(something(resp.LastEvaluatedKey))
    end
end

function report_failed_run(ctx::LiteCtx, gh::GitHubCtx, run::Item)
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
        err isa ErrorException && is_conditional_failure(err) && return
        rethrow()
    end

    context = parse_json(str(run, "context", "{}"), RunContext)
    (context.repo === nothing || context.issue === nothing) && return
    why = str(run, "failure_reason", "unspecified failure")
    mention = context.requester === nothing ? "" : "@$(something(context.requester)): "
    deliver_final(gh, something(context.repo), something(context.issue), run,
                  mention * "run `" * run_id * "` **failed** — " * why * ".")
    @info "reported failed run" run_id
end


## in-flight runs -> hourly status edits of the submission comment

"""
    eta_from_work(prev_at, prev_work, work_done, remaining, now)

Delta-based ETA in *work-seconds*, not job counts: `work_done` is the summed
actual duration of finished jobs, `remaining` the summed duration estimates of
unfinished ones. The window rate `Δwork_done/Δt` measures how many slot-seconds
the fleet actually completes per wall-second, so expensive packages running
early (the slow queue drains first) skew neither side — they add work to the
window exactly as they subtract it from `remaining`. Returns `nothing` when
there is no baseline tick yet or no forward progress — better no ETA than a
bogus one. Self-correcting: each tick re-derives the rate from the latest
window, so fleet scale-ups and spot losses fold in within an hour.
"""
function eta_from_work(prev_at::String, prev_work::Float64,
                       work_done::Float64, remaining::Float64, now::DateTime)
    prev_work < 0 && return nothing
    remaining > 0 || return nothing
    work_done > prev_work || return nothing
    prev = parse_isodate(prev_at)
    prev === nothing && return nothing
    elapsed_s = Dates.value(now - something(prev)) / 1000
    elapsed_s > 0 || return nothing
    rate = (work_done - prev_work) / elapsed_s
    return now + Dates.Second(round(Int, remaining / rate))
end

"""
Sum a run's finished work (actual durations) and remaining work (stored
duration estimates). Jobs without a stored estimate — runs expanded before
estimates were recorded — fall back to the mean actual duration of finished
jobs, or drop the ETA entirely when nothing has finished to average.
Returns `(work_done, remaining)`, with `remaining = -1.0` meaning unknown.
"""
function run_work(jobs::Vector{Item})
    work_done = 0.0
    ndone = 0
    for j in jobs
        if str(j, "status", "") in TERMINAL_STATUSES
            work_done += flt(j, "duration", 0.0)
            ndone += 1
        end
    end
    fallback = ndone > 0 ? work_done / ndone : -1.0
    remaining = 0.0
    for j in jobs
        str(j, "status", "") in TERMINAL_STATUSES && continue
        e = flt(j, "est", -1.0)
        e < 0 && (e = fallback)
        e < 0 && return (work_done, -1.0)
        remaining += e
    end
    return (work_done, remaining)
end

"One-line human summary of a run's configurations (\"primary: `...`, against: `...`\")."
function configs_summary(configs_json::String)
    configs = try
        parse_json(configs_json, Vector{ConfigInfo})
    catch
        ConfigInfo[]
    end
    isempty(configs) && return ""
    return join(("$(something(c.name, "?")): `$(something(c.julia, "?"))`" for c in configs), ", ")
end

"Humanize the span between two instants (\"3h 20m\", \"45m\", \"2d 4h\")."
function remaining_str(from::DateTime, to::DateTime)
    mins = max(0, Dates.value(to - from) ÷ 60_000)
    d, r = divrem(mins, 1440)
    h, m = divrem(r, 60)
    d > 0 && return "$(d)d $(h)h"
    h > 0 && return "$(h)h $(m)m"
    return "$(m)m"
end

"""
Compose the in-progress body for the submission comment. Pure so tests can pin
the exact rendering; `eta === nothing` means "don't print one". Deliberately
mention-free: GitHub notifies on mentions an edit adds, and only the final
message should ping the requester.
"""
function status_comment_body(run_id::String, config_desc::String, status::String,
                             completed::Int, total::Int, asof::DateTime,
                             eta::Union{Nothing,DateTime})
    desc = isempty(config_desc) ? "" : " ($config_desc)"
    stampfmt = dateformat"yyyy-mm-dd HH:MM \U\T\C"
    line = if status == "expanding"
        "expanding — building Julia and enumerating packages."
    elseif total > 0
        eta_note = eta === nothing ? "" :
            " Estimated completion: $(Dates.format(something(eta), stampfmt)) " *
            "(~$(remaining_str(asof, something(eta))) left)."
        "$completed/$total jobs completed.$eta_note"
    else
        "starting up."
    end
    return """
        Your package evaluation job has been submitted as run `$run_id`$desc.

        **Status** as of $(Dates.format(asof, stampfmt)): $line

        I will keep updating this comment (about once an hour) and post the report as a new comment when the run finishes."""
end

"""
One run's hourly progress edit. The conditional `status_commented_at` write is
throttle and concurrency claim in one: it only succeeds when the previous edit
is old enough and the run is still in flight, so overlapping invocations (and
the 60s interactive loop) collapse to at most one edit per hour, and a run
that just flipped done keeps its final report instead of getting a stale
"active" body written over it. Once claimed, the run's jobs are summed into
work done / work remaining (the jobs query is gated behind the claim on
purpose), and `status_work_done` is snapshotted as the next tick's ETA
baseline.
"""
function update_status_comment(ctx::LiteCtx, gh::GitHubCtx, run::Item;
                               min_interval::Dates.Minute=Dates.Minute(55))
    run_id = str(run, "run_id")
    # seal runs share the table but are internal: no comment, no report
    startswith(run_id, "seal-") && return nothing
    status = str(run, "status", "")
    completed = int(run, "completed_jobs", 0)
    total = int(run, "total_jobs", 0)
    now = Dates.now(UTC)
    payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
              "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
              "\"ConditionExpression\":\"#s IN (:expanding, :active) AND " *
              "(attribute_not_exists(status_commented_at) OR status_commented_at < :cutoff)\"," *
              "\"UpdateExpression\":\"SET status_commented_at = :now\"," *
              "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
              "\"ExpressionAttributeValues\":{" *
              "\":expanding\":{\"S\":\"expanding\"},\":active\":{\"S\":\"active\"}," *
              "\":cutoff\":{\"S\":$(JSON.json(isodate(now - min_interval)))}," *
              "\":now\":{\"S\":$(JSON.json(isodate(now)))}}}"
    try
        ddb(ctx, "UpdateItem", payload)
    catch err
        err isa ErrorException && is_conditional_failure(err) && return nothing
        rethrow()
    end
    comment_id = int(run, "comment_id", 0)
    context = parse_json(str(run, "context", "{}"), RunContext)
    if comment_id > 0 && context.repo !== nothing && context.issue !== nothing
        eta = nothing
        if status == "active"
            work_done, remaining = run_work(run_jobs(ctx, run_id; slim=true))
            if remaining >= 0
                eta = eta_from_work(str(run, "status_commented_at", ""),
                                    flt(run, "status_work_done", -1.0),
                                    work_done, remaining, now)
            end
            # whole seconds: string(::Float64) can go scientific, which DynamoDB's
            # number grammar does not accept
            snapshot = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
                       "\"Key\":{\"run_id\":{\"S\":$(JSON.json(run_id))}}," *
                       "\"UpdateExpression\":\"SET status_work_done = :w\"," *
                       "\"ExpressionAttributeValues\":{\":w\":{\"N\":\"$(round(Int, work_done))\"}}}"
            ddb(ctx, "UpdateItem", snapshot)
        end
        body = status_comment_body(run_id, configs_summary(str(run, "configs", "[]")),
                                   status, completed, total, now, eta)
        update_comment(gh, something(context.repo), comment_id, body)
        @info "updated status comment" run_id status completed total
    end
    # a work-in-progress report each tick, so the report page shows partial
    # results while the run executes. This full-item parse also took over the
    # forensic-canary role: the trimmed runtime historically segfaulted on it
    # in Lambda (foreign-thread MAPERR), and with the SEGVREPORT handler armed
    # every tick stays a diagnostic sample.
    if status == "active"
        publish_wip_report(ctx, run_id)
    end
    return nothing
end

"""
Publish a work-in-progress report for a still-active run (same objects as the
final report, marked `in_progress`; see `report_json`). The final report from
`report_finished_run` overwrites it — and if the run reaches a terminal state
*while* we generate, one regeneration makes the objects complete, so a stale
partial can never shadow the final even if this write lands after the
stream-triggered one.
"""
function publish_wip_report(ctx::LiteCtx, run_id::String)
    generate_report(ctx, run_id)
    str(get_run(ctx, run_id), "status", "") in ("expanding", "active") ||
        generate_report(ctx, run_id)
    return nothing
end

"""
The hourly tick over every in-flight run: edit the submission comment of runs
that recorded one, and publish a work-in-progress report for all of them.
"""
function update_status_comments(ctx::LiteCtx, gh::GitHubCtx)
    start_key = ""
    while true
        payload = "{\"TableName\":$(JSON.json(ctx.runs_table))," *
                  "\"FilterExpression\":\"#s IN (:expanding, :active)\"," *
                  "\"ExpressionAttributeNames\":{\"#s\":\"status\"}," *
                  "\"ExpressionAttributeValues\":{\":expanding\":{\"S\":\"expanding\"}," *
                  "\":active\":{\"S\":\"active\"}}" *
                  (isempty(start_key) ? "" : ",\"ExclusiveStartKey\":$start_key") * "}"
        resp = parse_json(ddb(ctx, "Scan", payload), ItemsResp)
        for run in something(resp.Items, Item[])
            try
                update_status_comment(ctx, gh, run)
            catch err
                @error "failed to update status comment" run_id=str(run, "run_id", "?") msg=error_message(err)
            end
        end
        resp.LastEvaluatedKey === nothing && break
        start_key = json_item(something(resp.LastEvaluatedKey))
    end
    return nothing
end


## report generation

report_key(run_id::String, name::String) = "runs/$run_id/report/$name"

s3_public_url(ctx::LiteCtx, key::String) =
    "https://$(ctx.bucket).s3.$(ctx.region).amazonaws.com/" *
    join(map(urlencode, split(key, '/')), '/')

# the interactive report page is a fixed static asset served from GitHub
# Pages (site/index.html, deployed by .github/workflows/pages.yml); it loads
# runs/<id>/report/report.json straight from the bucket, so runs upload only
# their data and the link just carries the run id
report_page() = get(ENV, "PKGEVAL_REPORT_PAGE", "https://pkgeval-reports.julialang.org/")
report_url(::LiteCtx, run_id::String) = report_page() * "?run=" * urlencode(run_id)

issuccess(status::String) = status == "test" || status == "load"
const TERMINAL_STATUSES = ("test", "load", "fail", "crash", "kill", "skip", "error")

status_emoji(status::String) = issuccess(status) ? "✅" :
                               status == "fail"  ? "❌" :
                               status == "crash" ? "💥" :
                               status == "kill"  ? "⏰" :
                               status == "skip"  ? "⏭" : "❓"

"""
All job items of a run. `slim=true` fetches only status/duration/est — the
fields the hourly status tick needs — cutting the response (and the parse
allocations, which have crashed the trimmed runtime on 24k-job runs) roughly
fivefold. Report generation wants the full items.
"""
function run_jobs(ctx::LiteCtx, run_id::String; slim::Bool=false)
    jobs = Item[]
    start_key = ""
    projection = slim ?
        ",\"ProjectionExpression\":\"#s, #d, est\"," *
        "\"ExpressionAttributeNames\":{\"#s\":\"status\",\"#d\":\"duration\"}" : ""
    while true
        payload = "{\"TableName\":$(JSON.json(ctx.jobs_table))," *
                  "\"KeyConditionExpression\":\"run_id = :run_id\"," *
                  "\"ExpressionAttributeValues\":{\":run_id\":{\"S\":$(JSON.json(run_id))}}" *
                  projection *
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

# staging buckets, probed for a finished build whose claim record has aged out
const STAGING_BUCKET_URLS = ["https://julialang-ephemeral-ci.s3.amazonaws.com",
                             "https://julialang-ephemeral-pr.s3.amazonaws.com",
                             "https://julialang-ephemeral-request.s3.amazonaws.com"]

# a claim younger than this is "a build in progress"; older claims without a
# staged artifact mean the build died, and the job should fail normally
const BUILD_CLAIM_FRESH_SECONDS = 3 * 60 * 60

"The (sha, variant) a config would need built, or nothing if not requestable."
function build_key_of(config::ConfigInfo)
    julia = config.julia
    julia === nothing && return nothing
    m = match(r"#([0-9a-f]{40})$", something(julia))
    m === nothing && return nothing
    flags = something(config.buildflags, String[])
    variant = isempty(flags) ? "linux" :
              Set(flags) == Set(["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"]) ? "linuxassert" :
              nothing
    variant === nothing && return nothing
    return (String(something(m.captures[1])), String(something(variant)))
end

"Whether the dead message's evaluation is blocked on a still-pending CI build."
function waiting_on_build(ctx::LiteCtx, ref::DeadRef)
    table = get(ENV, "PKGEVAL_BUILDS_TABLE", "")::String
    run = try
        get_run(ctx, something(ref.run_id))
    catch
        return false
    end
    configs = parse_json(str(run, "configs", "[]"), Vector{ConfigInfo})
    for config in configs
        # an expand message needs every config's Julia; a job message only its
        # own — but recycling on any pending build errs harmlessly long
        ref.expand || config.name === nothing ||
            something(config.name) == something(ref.config, "") || continue
        key = build_key_of(config)
        key === nothing && continue
        sha, variant = key
        if !isempty(table)
            claim = try
                payload = "{\"TableName\":$(JSON.json(table))," *
                          "\"Key\":{\"build_key\":{\"S\":$(JSON.json(string(sha, "/", variant)))}}}"
                parse_json(ddb(ctx, "GetItem", payload), ItemResp).Item
            catch
                nothing
            end
            if claim !== nothing
                requested = str(something(claim), "requested_at", "")
                # our ISO timestamps sort lexicographically, so freshness is a
                # string comparison — Dates *parsing* is untrimmable (its error
                # formatter), while Dates *formatting* is fine (isodate uses it)
                cutoff = Dates.format(
                    Dates.now(Dates.UTC) - Dates.Second(BUILD_CLAIM_FRESH_SECONDS),
                    Dates.dateformat"yyyy-mm-dd\THH:MM:SS\Z")
                (!isempty(requested) && requested >= cutoff) && return true
            end
        end
        # a finished build whose claim aged out: if it is staged, the retry
        # will succeed, so the message deserves recycling too
        filename = "julia-$(sha[1:10])-$(variant)-x86_64.tar.gz"
        for base in STAGING_BUCKET_URLS
            resp = try
                http_request("HEAD", "$base/bin/$sha/$filename")
            catch
                continue
            end
            resp.status == 200 && return true
        end
    end
    return false
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

"Format a dollar amount to whole cents; hand-rolled so --trim needs no Printf (or lpad)."
function dollars(x::Float64)
    cents = round(Int, x * 100)
    frac = cents % 100
    return "\$" * string(cents ÷ 100) * (frac < 10 ? ".0" : ".") * string(frac)
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
            str(run, "submitter", "?"), " at ", str(run, "created_at", "?"))
    # (a Set, not unique!: unique!'s issorted-with-keywords is untrimmable)
    donor_set = Set{String}()
    for j in jobs
        d = opt_str(j, "reused_from")
        d === nothing || push!(donor_set, something(d))
    end
    donors = sort!(collect(donor_set))
    isempty(donors) ||
        println(io, "- ", count(j -> opt_str(j, "reused_from") !== nothing, jobs),
                " baseline results reused from run ", join(map(d -> "`$d`", donors), ", "),
                " (pass `fresh_baseline = true` to re-evaluate)")
    total_cost = 0.0
    nmetered = 0
    for j in jobs
        # reused baselines legitimately carry no cost; count metering coverage
        # over the jobs that actually ran
        opt_str(j, "reused_from") === nothing || continue
        str(j, "status") in TERMINAL_STATUSES || continue
        if haskey(j, "cost") && j["cost"].N !== nothing
            total_cost += flt(j, "cost", 0.0)
            nmetered += 1
        end
    end
    nran = count(jobs) do j
        opt_str(j, "reused_from") === nothing && str(j, "status") in TERMINAL_STATUSES
    end
    if total_cost > 0
        if nmetered < nran
            # partial metering (e.g. cost recording deployed mid-run): the sum
            # is a floor, not an estimate — do not present it as the total
            println(io, "- compute cost: at least ", dollars(total_cost),
                    " (EC2 spot, job time only; only ", nmetered, " of ", nran,
                    " executed jobs were metered)")
        else
            println(io, "- estimated compute cost: ", dollars(total_cost),
                    " (EC2 spot, job time only; reused baselines cost nothing)")
        end
    end
    println(io)

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
    s3_put(ctx, report_key(run_id, "report.json"),
           report_json(ctx, run, jobs, configs, total_cost, nmetered < nran);
           content_type="application/json")
    return (; summary, markdown, url=report_url(ctx, run_id), cost=total_cost,
            cost_partial=(nmetered < nran))
end

## compact per-package dataset rendered by the report page
#
# Schema (kept in sync with site/index.html):
#   run     .id .bucket .bot .submitter .created .finished .trigger_url
#           .trigger_label .total_jobs .cpu_hours .cost .cost_partial
#           .in_progress .done_jobs .as_of   (mid-run snapshots only)
#           .primary/.against = {name, julia, repo, sha, flags}  (against only
#           for two-config comparisons; repo/sha empty when `julia` is not a
#           repo#sha spec)
#   reasons [[code, message], ...]  (severity ordering lives in the page)
#   pkgs    [[name, version, pstatus, preason, pduration,
#             astatus, areason, aduration, aversion-if-different,
#             plogdir, alogdir], ...]
#           statuses as single chars (t/l/f/c/k/s/e), reasons as indices into
#           `reasons` (-1 = none), durations in whole seconds
#   logdirs ["runs/<id>/logs/<config>", ...]  log directory of each job's
#           log_key, indexed by plogdir/alogdir (-1 = no log recorded); a
#           reused baseline's log lives under the donor run's prefix, so the
#           page must not assume this run's
#   sigs    [{label, n}, ...]  shared failure signatures: hard new failures
#           (fail/crash on primary, baseline OK) clustered by their stored
#           error_line, most common first; omitted when no lines were recorded
#   nfsig   {package: sig index, ...}  cluster membership for those packages

# grouping key for a stored error_line: collapse details that vary per package
# or process (addresses, source locations, LoadError nesting) but keep the
# message; the raw line stays as the cluster's display label
function normalize_error_line(line::String)
    s = replace(line, r"0x[0-9a-f]+" => "0xADDR")
    s = replace(s, r" at [^ ]+\.jl:\d+" => " at LOC")
    s = replace(s, "LoadError: " => "")
    return String(strip(s))
end

status_char(status::String) = status == "test"  ? "t" :
                              status == "load"  ? "l" :
                              status == "fail"  ? "f" :
                              status == "crash" ? "c" :
                              status == "kill"  ? "k" :
                              status == "skip"  ? "s" : "e"

function print_build_json(io::IO, key::String, cfg::ConfigInfo)
    julia = something(cfg.julia, "nightly")
    repo, sha = "", julia
    hash = findfirst('#', julia)
    if hash !== nothing
        repo = julia[1:prevind(julia, hash)]
        sha = julia[nextind(julia, hash):end]
    end
    print(io, ",", JSON.json(key), ":{\"name\":", JSON.json(something(cfg.name, key)),
          ",\"julia\":", JSON.json(julia),
          ",\"repo\":", JSON.json(repo), ",\"sha\":", JSON.json(sha), ",\"flags\":[")
    flags = cfg.buildflags
    if flags !== nothing
        for (i, flag) in enumerate(something(flags))
            i == 1 || print(io, ",")
            print(io, JSON.json(flag))
        end
    end
    print(io, "]}")
end

function report_json(ctx::LiteCtx, run::Item, jobs::Vector{Item},
                     configs::Vector{ConfigInfo}, total_cost::Float64,
                     cost_partial::Bool)
    io = IOBuffer()
    print(io, "{\"run\":{\"id\":", JSON.json(str(run, "run_id")))
    print(io, ",\"bucket\":",
          JSON.json("https://$(ctx.bucket).s3.$(ctx.region).amazonaws.com"))
    print(io, ",\"bot\":", JSON.json(bot_name()))
    print(io, ",\"submitter\":", JSON.json(str(run, "submitter", "?")))
    print(io, ",\"created\":", JSON.json(str(run, "created_at", "")))
    finished = opt_str(run, "finished_at")
    finished === nothing || print(io, ",\"finished\":", JSON.json(something(finished)))
    context = parse_json(str(run, "context", "{}"), RunContext)
    if context.repo !== nothing && context.issue !== nothing
        repo, issue = something(context.repo), something(context.issue)
        print(io, ",\"trigger_url\":", JSON.json(trigger_link(repo, issue, context.comment)),
              ",\"trigger_label\":", JSON.json("$repo#$issue"))
    end
    print_build_json(io, "primary", configs[1])
    length(configs) == 2 && print_build_json(io, "against", configs[2])
    # numbers go through string(): a non-String argument in these long vararg
    # print calls degrades Base.print's loop to Any-typed dispatch, which the
    # trim verifier rejects
    print(io, ",\"total_jobs\":", string(int(run, "total_jobs", 0)))
    # a report generated mid-run says so (see publish_wip_report): the page
    # banners it and covers only the jobs finished as of `as_of`
    if str(run, "status", "") != "done"
        ndone = count(j -> str(j, "status") in TERMINAL_STATUSES, jobs)
        print(io, ",\"in_progress\":true,\"done_jobs\":", string(ndone),
              ",\"as_of\":", JSON.json(isodate()))
    end
    cpu_seconds = 0.0
    for j in jobs
        cpu_seconds += flt(j, "duration", 0.0)
    end
    print(io, ",\"cpu_hours\":", string(round(cpu_seconds / 3600; digits=1)))
    print(io, ",\"cost\":", string(round(total_cost; digits=2)),
          ",\"cost_partial\":", cost_partial ? "true" : "false")
    print(io, "},\"reasons\":[")

    # reason vocabulary actually present in this run, as (code, message) pairs
    codes = String[]
    messages = Dict{String,String}()
    for j in jobs
        r = opt_str(j, "reason")
        r === nothing && continue
        code = something(r)
        if !haskey(messages, code)
            messages[code] = something(opt_str(j, "reason_message"), code)
            push!(codes, code)
        end
    end
    sort!(codes)
    ridx = Dict{String,Int}()
    for (i, code) in enumerate(codes)
        ridx[code] = i - 1
        i == 1 || print(io, ",")
        print(io, "[", JSON.json(code), ",", JSON.json(messages[code]), "]")
    end
    reason_idx(job::Item) = begin
        r = opt_str(job, "reason")
        r === nothing ? -1 : get(ridx, something(r), -1)
    end

    logdirs = String[]
    logdir_ids = Dict{String,Int}()
    logdir_idx(job::Item) = begin
        k = opt_str(job, "log_key")
        k === nothing && return -1
        key = something(k)
        # backwards byte scan for '/' (ASCII-safe): findlast(::Char, ::String)
        # routes through the generic Function-predicate findlast, which the
        # trim verifier rejects
        cu = codeunits(key)
        slash = 0
        for i in length(cu):-1:1
            if cu[i] == UInt8('/')
                slash = i
                break
            end
        end
        slash == 0 && return -1
        dir = key[1:prevind(key, slash)]
        get!(logdir_ids, dir) do
            push!(logdirs, dir)
            length(logdirs) - 1
        end
    end

    print(io, "],\"pkgs\":[")
    primary_name = something(configs[1].name, "primary")
    against_name = length(configs) == 2 ? something(configs[2].name, "against") : nothing
    by_pkg = Dict{String,Dict{String,Item}}()
    for job in jobs
        get!(by_pkg, str(job, "package"), Dict{String,Item}())[str(job, "config")] = job
    end
    first_row = true
    nf_lines = Tuple{String,String}[]  # (package, stored error_line) of hard new failures
    for pkg in sort!(collect(keys(by_pkg)))
        group = by_pkg[pkg]
        haskey(group, primary_name) || continue
        p = group[primary_name]
        pst = str(p, "status")
        pst in TERMINAL_STATUSES || continue
        a = against_name === nothing ? nothing : get(group, against_name, nothing)
        if a !== nothing && !(str(something(a), "status") in TERMINAL_STATUSES)
            a = nothing
        end
        # hard new failure: fail/crash on primary while the baseline passed
        # (single-config runs count every hard failure) — same classification
        # the page applies to build its new-failures section
        if (pst == "fail" || pst == "crash") &&
           (against_name === nothing ||
            (a !== nothing && issuccess(str(something(a), "status"))))
            el = opt_str(p, "error_line")
            el === nothing || push!(nf_lines, (pkg, something(el)))
        end
        pver = opt_str(p, "version")
        aver = a === nothing ? nothing : opt_str(something(a), "version")
        ver = something(pver, something(aver, ""))
        first_row || print(io, ",")
        first_row = false
        print(io, "[", JSON.json(pkg), ",", JSON.json(ver),
              ",", JSON.json(status_char(pst)),
              ",", string(reason_idx(p)),
              ",", string(round(Int, flt(p, "duration", 0.0))))
        if a === nothing
            print(io, ",\"\",-1,0,0,", string(logdir_idx(p)), ",-1]")
        else
            aa = something(a)
            print(io, ",", JSON.json(status_char(str(aa, "status"))),
                  ",", string(reason_idx(aa)),
                  ",", string(round(Int, flt(aa, "duration", 0.0))))
            changed = pver !== nothing && aver !== nothing && pver != aver
            print(io, ",", changed ? JSON.json(something(aver)) : "0",
                  ",", string(logdir_idx(p)), ",", string(logdir_idx(aa)), "]")
        end
    end
    print(io, "]")

    # shared failure signatures: cluster the collected error lines by their
    # normalized form; the page renders multi-package clusters as filters
    sig_ids = Dict{String,Int}()
    sig_labels = String[]
    sig_counts = Int[]
    assigned = Tuple{String,Int}[]
    for (pkg, line) in nf_lines
        key = normalize_error_line(line)
        idx = get!(sig_ids, key) do
            push!(sig_labels, line)
            push!(sig_counts, 0)
            length(sig_labels) - 1
        end
        sig_counts[idx + 1] += 1
        push!(assigned, (pkg, idx))
    end
    if !isempty(sig_labels)
        # most common first; ties keep first-seen order (plain sortperm — the
        # keyword-sorting paths don't survive the trim verifier)
        perm = sortperm([(-sig_counts[i], i) for i in 1:length(sig_counts)])
        remap = Vector{Int}(undef, length(perm))
        for (newi, oldi) in enumerate(perm)
            remap[oldi] = newi - 1
        end
        print(io, ",\"sigs\":[")
        for (i, oldi) in enumerate(perm)
            i == 1 || print(io, ",")
            print(io, "{\"label\":", JSON.json(sig_labels[oldi]),
                  ",\"n\":", string(sig_counts[oldi]), "}")
        end
        print(io, "],\"nfsig\":{")
        for (i, (pkg, idx)) in enumerate(assigned)
            i == 1 || print(io, ",")
            print(io, JSON.json(pkg), ":", string(remap[idx + 1]))
        end
        print(io, "}")
    end

    print(io, ",\"logdirs\":[")
    for (i, dir) in enumerate(logdirs)
        i == 1 || print(io, ",")
        print(io, JSON.json(dir))
    end
    print(io, "]}")
    return String(take!(io))
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

"One poll iteration: handle new commands, report finished runs, edit progress."
function handle_invocation(ctx::LiteCtx=ctx_from_env(), gh::GitHubCtx=bot_gh())
    name = bot_name()
    poll_mentions(ctx, gh, name)
    # heal finished-but-stuck runs first, so check_finished_runs can report
    # them within the same invocation
    reconcile_stuck_runs(ctx)
    check_finished_runs(ctx, gh)
    check_failed_runs(ctx, gh)
    # after the checks above: a run that just finished or failed is reported
    # there and excluded from the status scan, instead of racing it
    update_status_comments(ctx, gh)
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
    dead_bodies::Vector{String}         # SQS records (the jobs DLQ)
    method::Union{Nothing,String}       # Function URL fields
    signature::Union{Nothing,String}    # x-hub-signature-256
    ghevent::Union{Nothing,String}      # x-github-event
    body::Union{Nothing,String}
    is_base64::Bool
    canary::Union{Nothing,String}       # direct invoke: forensic parse of this run
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
    dead_bodies = String[]
    method = Ref{Union{Nothing,String}}(nothing)
    signature = Ref{Union{Nothing,String}}(nothing)
    ghevent = Ref{Union{Nothing,String}}(nothing)
    body = Ref{Union{Nothing,String}}(nothing)
    is_base64 = Ref(false)
    canary = Ref{Union{Nothing,String}}(nothing)
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
                    if rk == "dynamodb"
                        return JSON.applyobject(rv) do dk, dv
                            isnullval(dv) && return nothing
                            dk == "NewImage" || return nothing
                            image, image_pos = json_make(Item, dv)
                            push!(new_images, image)
                            return image_pos
                        end
                    elseif rk == "body"
                        # an SQS record: a message the jobs DLQ gave up on
                        bstr, bpos = json_string(rv)
                        push!(dead_bodies, bstr)
                        return bpos
                    end
                    return nothing
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
        elseif k == "canary"
            cs, cp = json_string(v); canary[] = cs; return cp
        elseif k == "isBase64Encoded"
            b, p = json_bool(v); is_base64[] = b; return p
        end
        return nothing
    end
    return TopEvent(new_images, dead_bodies, method[], signature[], ghevent[], body[], is_base64[], canary[]),
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
    if event.canary !== nothing
        # forensic direct invoke: run the crash-suspect full-item parse on
        # demand (no claim, no side effects) with the SEGVREPORT handler armed
        jobs = run_jobs(ctx, something(event.canary))
        @info "forensic canary parse survived" n=length(jobs)
        return "{\"ok\":true,\"jobs\":" * string(length(jobs)) * "}"
    end
    if !isempty(event.dead_bodies)
        # the jobs DLQ: messages the queue gave up on become recorded results,
        # so runs still complete (with errors) and reports still get posted
        # instead of the run waiting forever on a job that will never arrive
        handle_dead_messages(ctx, gh, event.dead_bodies)
        return "{\"ok\":true}"
    elseif !isempty(event.new_images)
        # runs that just reached a terminal state (the event source mapping
        # filters on status). Runs failed via mark_run_failed carry `reported`
        # already, so report_failed_run's claim quietly skips them here.
        for run in event.new_images
            status = str(run, "status", "")
            if status == "done"
                report_finished_run(ctx, gh, run)
            elseif status == "failed"
                report_failed_run(ctx, gh, run)
            end
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
