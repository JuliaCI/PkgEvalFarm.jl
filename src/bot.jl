# The @nanosoldier2 bot: a stateless poller that turns GitHub PR comments into runs
# and posts the report back when a run finishes.
#
# It shares no infrastructure with the farm beyond the submitter role: it can run
# anywhere (a cron job is fine — all state lives in the runs table and GitHub).

const BOT_COMMAND = r"@([\w-]+)\s+runtests\((.*?)\)"s

github_api(path) = "https://api.github.com" * path

function bot_token()
    token = get(ENV, "NANOSOLDIER2_GITHUB_TOKEN", get(ENV, "GITHUB_TOKEN", ""))
    isempty(token) && error("set NANOSOLDIER2_GITHUB_TOKEN to the bot account's token")
    return token
end

function gh_request(method, path, token; body=nothing, params=nothing)
    url = startswith(path, "http") ? path : github_api(path)
    params === nothing || (url *= "?" * HTTP.URIs.escapeuri(params))
    resp = HTTP.request(method, url,
        ["Authorization" => "Bearer $token", "Accept" => "application/vnd.github+json",
         "X-GitHub-Api-Version" => "2022-11-28"],
        body === nothing ? "" : JSON.json(body);
        status_exception=true)
    isempty(resp.body) && return nothing
    return JSON.parse(String(resp.body))
end

"""
    parse_command(body) -> Union{Nothing,NamedTuple}

Parse a `@<bot> runtests(...)` comment. Supported forms:

    @nanosoldier2 runtests()                       # all packages
    @nanosoldier2 runtests(["Foo", "Bar"])         # a subset
    @nanosoldier2 runtests(vs = ":master")         # against a branch of the same repo
    @nanosoldier2 runtests(vs = "@0123abc")        # against a commit of the same repo
    @nanosoldier2 runtests(vs = "v1.12.0")         # against a Julia release

The argument expression is parsed, never evaluated.
"""
function parse_command(body::AbstractString)
    m = match(BOT_COMMAND, body)
    m === nothing && return nothing
    packages = String[]
    vs = nothing
    args = strip(m.captures[2])
    if !isempty(args)
        expr = try
            Meta.parse("runtests($args)")
        catch
            return (; error="could not parse command arguments")
        end
        Meta.isexpr(expr, :call) || return (; error="could not parse command arguments")
        for arg in expr.args[2:end]
            if Meta.isexpr(arg, :kw) && arg.args[1] === :vs && arg.args[2] isa String
                vs = arg.args[2]
            elseif Meta.isexpr(arg, :(=)) && arg.args[1] === :vs && arg.args[2] isa String
                vs = arg.args[2]
            elseif Meta.isexpr(arg, :vect) && all(x -> x isa String, arg.args)
                packages = String[arg.args...]
            elseif arg === :ALL
                # explicit "all packages"
            else
                return (; error="unsupported argument `$arg`")
            end
        end
    end
    return (; packages, vs, error=nothing)
end

"Resolve a `vs` spec against the repo the PR targets."
function resolve_vs(vs::AbstractString, repo::AbstractString)
    startswith(vs, ":") && return "$repo#$(chop(vs; head=1, tail=0))"
    startswith(vs, "@") && return "$repo#$(chop(vs; head=1, tail=0))"
    return String(vs)
end

"""
    run_bot(; broker=nothing, interval=60, bot_name="nanosoldier2")

Poll GitHub for `@<bot_name> runtests(...)` mentions, submit runs for them, and post
reports back when runs finish. Requires submitter credentials (via the broker) and a
GitHub token for the bot account.
"""
function run_bot(; broker::Union{AbstractString,Nothing}=nothing, interval::Int=60,
                 bot_name::AbstractString="nanosoldier2", once::Bool=false)
    token = bot_token()
    ctx, user = farm_ctx(; broker, role="submitter")
    @info "bot started" bot_name submitter=user
    while true
        try
            poll_mentions(ctx, token, bot_name)
            check_active_runs(ctx, token)
        catch err
            err isa InterruptException && break
            @error "bot iteration failed" exception=(err, catch_backtrace())
        end
        once && break
        sleep(interval)
    end
end

function poll_mentions(ctx::FarmCtx, token, bot_name)
    threads = gh_request("GET", "/notifications", token;
                         params=["participating" => "true"])
    for thread in something(threads, [])
        thread["reason"] == "mention" || continue
        thread["subject"]["type"] in ("Issue", "PullRequest") || continue
        try
            handle_mention(ctx, token, bot_name, thread)
        catch err
            @error "failed to handle mention" url=thread["subject"]["url"] exception=(err, catch_backtrace())
        finally
            # mark read regardless: better to drop a command than to retry-spam a PR
            gh_request("PATCH", "/notifications/threads/$(thread["id"])", token)
        end
    end
end

function handle_mention(ctx::FarmCtx, token, bot_name, thread)
    comment_url = get(thread["subject"], "latest_comment_url", nothing)
    comment_url === nothing && return
    comment = gh_request("GET", comment_url, token)
    command = parse_command(get(comment, "body", ""))
    command === nothing && return
    occursin("@$bot_name", comment["body"]) || return

    issue_url = thread["subject"]["url"]
    issue = gh_request("GET", issue_url, token)
    repo = issue["repository_url"] === nothing ? nothing :
           replace(issue["repository_url"], github_api("/repos/") => "")
    number = issue["number"]
    reply(msg) = gh_request("POST", "/repos/$repo/issues/$number/comments", token;
                            body=Dict("body" => msg))

    if command.error !== nothing
        reply("Sorry @$(comment["user"]["login"]), I couldn't parse that: $(command.error)")
        return
    end
    if !haskey(issue, "pull_request")
        reply("`runtests` only works on pull requests.")
        return
    end

    pr = gh_request("GET", issue["pull_request"]["url"], token)
    primary = "$repo#$(pr["head"]["sha"])"
    against = command.vs === nothing ? "$repo#$(pr["base"]["ref"])" :
              resolve_vs(command.vs, repo)
    configs = build_configs(primary; against,
                            buildflags=["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"])
    context = Dict{String,Any}("repo" => repo, "issue" => number,
                               "requester" => comment["user"]["login"])
    run_id = submit_run(ctx; configs, packages=command.packages, context,
                        submitter="$(comment["user"]["login"]) via @$bot_name")
    reply("""
        Your package evaluation job has been submitted as run `$run_id` \
        (primary: `$primary`, against: `$against`). \
        I will reply here once it finishes.""")
end

"Post reports for runs that finished since the last poll."
function check_active_runs(ctx::FarmCtx, token)
    resp = aws_retry() do
        Dynamodb.scan(ctx.cfg.runs_table,
            Dict("FilterExpression" => "#s = :done AND attribute_not_exists(reported)",
                 "ExpressionAttributeNames" => Dict("#s" => "status"),
                 "ExpressionAttributeValues" => ddb_item(Dict(":done" => "done")));
            aws_config=ctx.aws)
    end
    for item in get(resp, "Items", [])
        run = ddb_parse(item)
        context = JSON.parse(run["context"])
        run_id = run["run_id"]

        # claim the reporting so concurrent bots don't double-post
        try
            Dynamodb.update_item(ddb_item(Dict("run_id" => run_id)), ctx.cfg.runs_table,
                Dict("ConditionExpression" => "attribute_not_exists(reported)",
                     "UpdateExpression" => "SET reported = :t",
                     "ExpressionAttributeValues" => ddb_item(Dict(":t" => true)));
                aws_config=ctx.aws)
        catch err
            err isa AWS.AWSException && err.code == "ConditionalCheckFailedException" && continue
            rethrow()
        end

        report = generate_report(ctx, run_id)
        haskey(context, "repo") || continue
        requester = get(context, "requester", nothing)
        mention = requester === nothing ? "" : "@$requester: "
        gh_request("POST", "/repos/$(context["repo"])/issues/$(context["issue"])/comments",
                   token;
                   body=Dict("body" => """
                       $(mention)run `$run_id` finished — **$(report.summary)**

                       Full report: $(report_url(ctx, run_id))"""))
        @info "posted report" run_id
    end
end
