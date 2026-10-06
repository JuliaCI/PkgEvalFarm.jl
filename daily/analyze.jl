# Analyze the farm's daily runs, for the site's Daily page and for PR runs.
#
#   julia --project=daily daily/analyze.jl <output dir> [<cache dir>]
#
# Reads the summary the bot publishes for each finished daily
# (runs/daily-YYYY-MM-DD/report/daily.json) and writes to the output directory:
#
#   index.json        one entry per daily: date, run, commit, Julia version and status
#                     counts, with days that look like infrastructure flukes marked
#   performance.json  package test time per daily relative to the newest, computed the two
#                     ways Nanosoldier's charts did
#   unreliable.json   packages that fail too often to be worth testing on PR runs
#
# This ports NanosoldierReports' tools/pkgeval_analysis, which did the same for
# Nanosoldier's dailies. Summaries are immutable once published, so they are cached.

using Dates, Downloads, JSON

const FARM = get(ENV, "PKGEVAL_FARM", "https://pkgeval.s3.us-east-2.amazonaws.com")
const FIRST_DAILY = Date(2026, 10, 1)
const STATUSES = ("test", "fail", "crash", "kill", "skip")

struct Daily
    date::Date
    run::String
    sha::String
    version::String
    tests::Dict{String,Any}
end

# the body, or `nothing` when the object doesn't exist (S3 answers 403 for missing keys
# in a bucket that isn't publicly listable)
function fetch_text(url)
    io = IOBuffer()
    try
        Downloads.download(url, io)
    catch err
        err isa Downloads.RequestError && err.response.status in (403, 404) && return nothing
        rethrow()
    end
    return String(take!(io))
end

function load_dailies(cache)
    mkpath(cache)
    versions_file = joinpath(cache, "versions.json")
    versions = isfile(versions_file) ? JSON.parsefile(versions_file; dicttype=Dict{String,Any}) :
               Dict{String,Any}()
    dailies = Daily[]
    for date in FIRST_DAILY:Day(1):Date(now(UTC))
        run = "daily-" * Dates.format(date, dateformat"yyyy-mm-dd")
        file = joinpath(cache, "$run.json")
        if !isfile(file)
            text = fetch_text("$FARM/runs/$run/report/daily.json")
            text === nothing && continue
            write(file, text)
        end
        summary = JSON.parsefile(file; dicttype=Dict{String,Any})
        sha = String(summary["build"]["sha"])
        version = get(versions, sha, "")
        if isempty(version)
            # not cached when missing, so a later build tries again
            text = fetch_text("https://raw.githubusercontent.com/JuliaLang/julia/$sha/VERSION")
            text === nothing || (version = versions[sha] = String(strip(text)))
        end
        push!(dailies, Daily(date, run, sha, version, summary["tests"]))
    end
    write(versions_file, JSON.json(versions))
    return dailies
end

package_version(test) = test["version"] === nothing ? nothing : tryparse(VersionNumber, test["version"])

function status_counts(daily)
    counts = Dict(s => 0 for s in STATUSES)
    for test in values(daily.tests)
        status = test["status"]
        counts[status in STATUSES ? status : "fail"] += 1
    end
    return counts
end

# Days that look like infrastructure trouble rather than Julia's doing: far fewer packages
# passed than on the week of dailies before, or far fewer were evaluated. Nanosoldier's
# chart instead flagged any day where under half the packages passed, which on master has
# been most days since 2025 (its normal pass rate is about 48%).
function fluke_days(dailies; window=7, min_pass_ratio=0.8)
    counts = status_counts.(dailies)
    passed = [c["test"] for c in counts]
    totals = [sum(values(c)) for c in counts]
    return map(eachindex(dailies)) do i
        passed[i] < 0.2 * totals[i] && return true
        prev = max(1, i - window):i-1
        isempty(prev) && return false
        return passed[i] < min_pass_ratio * median(passed[prev]) ||
               totals[i] < median(totals[prev]) - 100
    end
end

median(xs) = (s = sort(xs); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

function index_entries(dailies)
    flukes = fluke_days(dailies)
    entries = Dict{String,Any}[]
    for (i, daily) in enumerate(dailies)
        counts = status_counts(daily)
        total = sum(values(counts))
        # the newest day is always drawn, so the chart stays current
        outlier = flukes[i] && i < length(dailies)
        push!(entries, Dict("date" => string(daily.date), "run" => daily.run, "sha" => daily.sha,
                            "version" => daily.version, "counts" => counts, "total" => total,
                            "outlier" => outlier,
                            "summary" => "$FARM/runs/$(daily.run)/report/daily.json"))
    end
    return entries
end

# Successful tests with a known package version and a real duration (a duration of 0 means
# PkgEval terminated after testing had completed), as (daily index, package, version, duration).
function timing_rows(dailies)
    rows = Tuple{Int,String,VersionNumber,Float64}[]
    for (i, daily) in enumerate(dailies), (pkg, test) in daily.tests
        test["status"] == "test" || continue
        version = package_version(test)
        version === nothing && continue
        duration = Float64(test["duration"])
        duration > 0 && push!(rows, (i, pkg, version, duration))
    end
    return rows
end

# Test time relative to the newest daily, from the package versions tested on that daily.
# Days covering less than half the ecosystem are left out.
function simple_ratios(dailies, rows)
    isempty(rows) && return fill(nothing, length(dailies))
    newest = maximum(first, rows)
    reference = Dict((pkg, version) => duration for (i, pkg, version, duration) in rows if i == newest)
    durations = zeros(length(dailies)); references = zeros(length(dailies)); points = zeros(Int, length(dailies))
    for (i, pkg, version, duration) in rows
        ref = get(reference, (pkg, version), nothing)
        ref === nothing && continue
        durations[i] += duration
        references[i] += ref
        points[i] += 1
    end
    enough = 0.5 * maximum(points)
    return [points[i] > 0 && points[i] >= enough ? durations[i] / references[i] : nothing
            for i in eachindex(dailies)]
end

# Like `simple_ratios`, but also uses package versions that the newest daily didn't test:
# each version's durations are compared with its own latest test, and that daily's ratio
# carries the comparison forward to the newest. (Nanosoldier's chart described this but
# added the intermediate comparisons without that last step, understating the chained
# ratios; the numbers here differ from its chart accordingly.)
function full_ratios(dailies, rows)
    days = sort!(unique(first.(rows)))
    n = length(days)
    n == 0 && return fill(nothing, length(dailies))
    pos = Dict(day => k for (k, day) in enumerate(days))
    groups = Dict{Tuple{String,VersionNumber},Vector{Tuple{Int,Float64}}}()
    for (i, pkg, version, duration) in rows
        push!(get!(groups, (pkg, version), Tuple{Int,Float64}[]), (pos[i], duration))
    end
    ratios = ones(n, n)
    weights = zeros(n, n)
    for tests in values(groups)
        sort!(tests)
        ref, ref_duration = last(tests)
        # running mean of duration / ref_duration, weighted by ref_duration
        for (k, duration) in tests[1:end-1]
            new_weight = weights[k, ref] + ref_duration
            ratios[k, ref] = (ratios[k, ref] * weights[k, ref] + duration) / new_weight
            weights[k, ref] = new_weight
        end
    end
    result = Vector{Union{Nothing,Float64}}(nothing, length(dailies))
    result[days[n]] = 1.0
    for k in n-1:-1:1
        weight = weights[k, n]
        duration = ratios[k, n] * weight
        for k′ in k+1:n-1
            chained = result[days[k′]]   # day k′ relative to the newest, computed above
            chained === nothing && continue
            duration += ratios[k, k′] * chained * weights[k, k′]
            weight += weights[k, k′]
        end
        weight > 0 && (result[days[k]] = duration / weight)
    end
    return result
end

# Packages whose latest version failed at least 75% of at least 5 tests in the last 30 days.
# PR runs only install and load these, since their failures say little about the PR.
# Fluke days and skips are left out: neither says anything about the package. (Nanosoldier
# counted both, so its list also held every package skipped as uninstallable or untestable.)
function unreliable_packages(dailies; window=Day(30), min_tests=5, min_failure_ratio=0.75,
                             today=Date(now(UTC)))
    since = today - window
    flukes = fluke_days(dailies)
    history = Dict{String,Vector{Tuple{Union{Nothing,VersionNumber},Bool}}}()
    for (daily, fluke) in zip(dailies, flukes)
        daily.date >= since && !fluke || continue
        for (pkg, test) in daily.tests
            test["status"] == "skip" && continue
            push!(get!(history, pkg, Tuple{Union{Nothing,VersionNumber},Bool}[]),
                  (package_version(test), test["status"] != "test"))
        end
    end
    unreliable = String[]
    for (pkg, tests) in history
        versions = [v for (v, _) in tests if v !== nothing]
        if !isempty(versions)
            latest = maximum(versions)
            tests = tests[findfirst(t -> t[1] == latest, tests):end]
        end
        failures = count(last, tests)
        length(tests) >= min_tests && failures / length(tests) >= min_failure_ratio && push!(unreliable, pkg)
    end
    return sort!(unreliable)
end

function main(out, cache=joinpath(@__DIR__, ".cache"))
    mkpath(out)
    dailies = load_dailies(cache)
    rows = timing_rows(dailies)
    write(joinpath(out, "index.json"), JSON.json(index_entries(dailies)))
    write(joinpath(out, "performance.json"), JSON.json(
        [Dict("date" => string(daily.date), "simple" => simple, "full" => full)
         for (daily, simple, full) in zip(dailies, simple_ratios(dailies, rows), full_ratios(dailies, rows))]))
    write(joinpath(out, "unreliable.json"), JSON.json(Dict(
        "generated" => string(now(UTC)), "window_days" => 30, "min_tests" => 5,
        "min_failure_ratio" => 0.75, "unreliable" => unreliable_packages(dailies))))
    @info "analyzed daily runs" n=length(dailies)
end

abspath(PROGRAM_FILE) == @__FILE__() && main(ARGS...)
