# Aggregating a finished run into a Nanosoldier-style comparison report.

s3_public_url(cfg::FarmConfig, key) =
    "https://$(cfg.bucket).s3.$(cfg.region).amazonaws.com/" *
    join(map(HTTP.URIs.escapeuri, split(key, '/')), '/')

status_emoji(status) = issuccess(status) ? "✅" :
                       status == "fail"  ? "❌" :
                       status == "crash" ? "💥" :
                       status == "kill"  ? "⏰" :
                       status == "skip"  ? "⏭" : "❓"

reason_message(reason::Nothing) = ""
reason_message(reason::AbstractString) = PkgEval.reason_message(Symbol(reason))

"""
    generate_report(ctx, run_id; upload=true) -> (; markdown, summary)

Aggregate all job results of a run into a markdown comparison report (primary vs
against when the run has two configurations) plus a machine-readable `db.json`,
optionally uploading both to `runs/<run_id>/report/` in S3.
"""
function generate_report(ctx::FarmCtx, run_id::AbstractString; upload::Bool=true)
    run = get_run(ctx, run_id)
    jobs = run_jobs(ctx, run_id)
    config_names = [c["name"] for c in run["configs"]]

    by_config = Dict(name => Dict{String,Dict{String,Any}}() for name in config_names)
    for job in jobs
        by_config[job["config"]][job["package"]] = job
    end

    io = IOBuffer()
    println(io, "# PkgEval report — run `$run_id`\n")
    for c in run["configs"]
        println(io, "- **$(c["name"])**: `julia = $(get(c, "julia", "nightly"))`",
                isempty(get(c, "buildflags", [])) ? "" : ", `buildflags = $(c["buildflags"])`")
    end
    ndone = count(j -> j["status"] in TERMINAL_STATUSES, jobs)
    println(io, "- jobs: $ndone/$(length(jobs)) finished, submitted by $(run["submitter"]) at $(run["created_at"])\n")

    loglink(job) = begin
        key = get(job, "log_key", nothing)
        key === nothing ? "no log" : "[log]($(s3_public_url(ctx.cfg, key)))"
    end
    describe(job) = begin
        version = get(job, "version", nothing)
        reason = get(job, "reason", nothing)
        string("**$(job["package"])**", version === nothing ? "" : " v$version",
               ": $(status_emoji(job["status"])) $(job["status"])",
               reason === nothing ? "" : " ($(reason_message(reason)))",
               " — ", loglink(job))
    end

    summary = ""
    if length(config_names) == 2
        primary, against = by_config[config_names[1]], by_config[config_names[2]]
        packages = sort!(collect(union(keys(primary), keys(against))))
        new_failures = String[]
        now_passing = String[]
        still_failing = String[]
        for pkg in packages
            p, a = get(primary, pkg, nothing), get(against, pkg, nothing)
            (p === nothing || a === nothing) && continue
            p["status"] in TERMINAL_STATUSES && a["status"] in TERMINAL_STATUSES || continue
            pok, aok = issuccess(p["status"]), issuccess(a["status"])
            if !pok && aok && p["status"] != "skip"
                push!(new_failures, "- " * describe(p) * " (vs. $(status_emoji(a["status"])) — $(loglink(a)))")
            elseif pok && !aok && a["status"] != "skip"
                push!(now_passing, "- " * describe(p))
            elseif !pok && !aok && p["status"] != "skip"
                push!(still_failing, "- " * describe(p))
            end
        end

        summary = isempty(new_failures) ? "no new package failures ✅" :
                  "possible new issues: $(length(new_failures)) package$(length(new_failures) == 1 ? "" : "s") ❌"

        section(title, entries; open=false) = if !isempty(entries)
            println(io, "<details$(open ? " open" : "")><summary>$title ($(length(entries)))</summary>\n")
            foreach(e -> println(io, e), entries)
            println(io, "\n</details>\n")
        end
        println(io, "**", summary, "**\n")
        section("❌ Packages that failed on primary but not on against", new_failures; open=true)
        section("✅ Packages that now pass", now_passing)
        section("💔 Packages that failed on both", still_failing)
    else
        counts = Dict{String,Int}()
        for job in jobs
            counts[job["status"]] = get(counts, job["status"], 0) + 1
        end
        nfail = sum(get(counts, s, 0) for s in ("fail", "crash", "kill", "error"))
        summary = "$(get(counts, "test", 0) + get(counts, "load", 0)) passed, $nfail failed"
        println(io, "**", summary, "**\n")
        for status in TERMINAL_STATUSES
            entries = ["- " * describe(job) for job in jobs if job["status"] == status]
            isempty(entries) && continue
            issuccess(status) && continue
            println(io, "<details><summary>$(status_emoji(status)) $status ($(length(entries)))</summary>\n")
            foreach(e -> println(io, e), entries)
            println(io, "\n</details>\n")
        end
    end
    markdown = String(take!(io))

    if upload
        S3.put_object(ctx.cfg.bucket, report_key(run_id, "report.md"),
            Dict("body" => markdown,
                 "headers" => Dict("Content-Type" => "text/markdown; charset=utf-8"));
            aws_config=ctx.aws)
        S3.put_object(ctx.cfg.bucket, report_key(run_id, "db.json"),
            Dict("body" => JSON.json(Dict("run" => run, "jobs" => jobs)),
                 "headers" => Dict("Content-Type" => "application/json"));
            aws_config=ctx.aws)
    end
    return (; markdown, summary)
end

report_url(ctx::FarmCtx, run_id) = s3_public_url(ctx.cfg, report_key(run_id, "report.md"))
