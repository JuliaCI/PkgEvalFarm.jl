"""
The @nanosoldier2 bot: turns GitHub PR comments (`@nanosoldier2 runtests(...)`) into
farm runs and posts the report back when a run finishes.

Deployed as a juliac-compiled Lambda invoked on an EventBridge schedule; each
invocation performs one poll (mentions + finished runs). It carries the submitter IAM
policy on its execution role, so unlike human submitters it needs neither the broker
nor GitHub team membership — only its GitHub account token (`NANOSOLDIER2_GITHUB_TOKEN`).

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
                 error_message, lambda_loop, ctx_from_env

export run_bot, handle_invocation


## command parsing (pure)

const BOT_COMMAND = r"@([\w-]+)\s+runtests\((.*?)\)"s

struct Command
    packages::Vector{String}
    vs::Union{Nothing,String}
    error::Union{Nothing,String}
end

"""
    parse_command(body) -> Union{Nothing,Command}

Parse a `@<bot> runtests(...)` comment. Supported forms:

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
                packages = String[(arg::Expr).args...]
            elseif arg === :ALL
                # explicit "all packages"
            else
                return Command(packages, vs, "unsupported argument `$arg`")
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

parse_json(body::String, ::Type{T}) where {T} = JSON.parse(body, T)::T


## DynamoDB response shapes

struct ItemsResp                       # Scan / Query
    Items::Union{Nothing,Vector{Item}}
    LastEvaluatedKey::Union{Nothing,Item}
end
struct ItemResp                        # GetItem
    Item::Union{Nothing,Item}
end


## run submission (mirrors PkgEvalFarm.create_run: one PutItem + one expand message)

isodate() = Dates.format(Dates.now(UTC), dateformat"yyyy-mm-dd\THH:MM:SS\Z")

function new_run_id()
    suffix = join(rand("0123456789abcdef", 6))
    Dates.format(Dates.now(UTC), "yyyymmdd-HHMMSS") * "-" * suffix
end

"Serialized `Configuration` the workers will reconstruct (modified settings only)."
function config_json(name::String, julia::String; assertions::Bool)
    flags = assertions ? "[\"LLVM_ASSERTIONS=1\",\"FORCE_ASSERTIONS=1\"]" : "[]"
    "{\"name\":$(JSON.json(name)),\"julia\":$(JSON.json(julia)),\"buildflags\":$flags}"
end

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
    ddb(ctx, "PutItem", payload)
    sqs_send_message(ctx, "{\"run_id\":$(JSON.json(run_id)),\"expand\":true}")
    return run_id
end


## polling GitHub for commands

function bot_gh()
    token = get(ENV, "NANOSOLDIER2_GITHUB_TOKEN", get(ENV, "GITHUB_TOKEN", ""))
    isempty(token) && error("set NANOSOLDIER2_GITHUB_TOKEN to the bot account's token")
    return GitHubCtx(token)
end

bot_name() = get(ENV, "BOT_NAME", "nanosoldier2")

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

function handle_mention(ctx::LiteCtx, gh::GitHubCtx, name::String,
                        subject::NotificationSubject)
    comment_url = subject.latest_comment_url
    comment_url === nothing && return
    resp = github_request(gh, "GET", something(comment_url))
    resp.status == 200 || return
    comment = parse_json(resp.body, GhComment)
    comment_body = comment.body
    comment_body === nothing && return
    occursin("@$name", something(comment_body)) || return
    command = parse_command(something(comment_body))
    command === nothing && return
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

    if command.error !== nothing
        post_comment(gh, repo, number,
                     "Sorry @$requester, I couldn't parse that: $(something(command.error))")
        return
    end
    if issue.pull_request === nothing || something(issue.pull_request).url === nothing
        post_comment(gh, repo, number, "`runtests` only works on pull requests.")
        return
    end

    resp = github_request(gh, "GET", something(something(issue.pull_request).url))
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
    run_id = create_run(ctx; configs_json, packages=command.packages, context_json,
                        submitter="$requester via @$name")
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
        is_conditional_failure(err) && return
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

"Lambda entry: each scheduled event triggers one poll iteration."
function lambda_main()
    lambda_loop() do event
        handle_invocation()
        return "{\"ok\":true}"
    end
end

end # module
