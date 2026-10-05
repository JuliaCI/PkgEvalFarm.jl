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
        version = get!(versions, sha) do
            text = fetch_text("https://raw.githubusercontent.com/JuliaLang/julia/$sha/VERSION")
            text === nothing ? "" : strip(text)
        end
        push!(dailies, Daily(date, run, sha, version, summary["tests"]))
    end
    write(versions_file, JSON.json(versions))
    return dailies
end

package_version(test) = test["version"] === nothing ? nothing : tryparse(VersionNumber, test["version"])

function index_entries(dailies)
    entries = Dict{String,Any}[]
    kept_total = nothing
    for (i, daily) in enumerate(dailies)
        counts = Dict(s => 0 for s in STATUSES)
        for test in values(daily.tests)
            status = test["status"]
            counts[status in STATUSES ? status : "fail"] += 1
        end
        total = sum(values(counts))
        # Nanosoldier's chart skipped days that look like infrastructure trouble rather
        # than Julia's doing, except the newest so the chart stays current
        outlier = i < length(dailies) &&
            (counts["test"] < 0.5 * total || (kept_total !== nothing && total < kept_total - 100))
        outlier || (kept_total = total)
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
# carries the comparison forward to the newest.
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
            duration += ratios[k, k′] * weights[k, k′]
            weight += weights[k, k′]
        end
        weight > 0 && (result[days[k]] = duration / weight)
    end
    return result
end

# Packages whose latest version failed at least 75% of at least 5 tests in the last 30 days.
# PR runs only install and load these, since their failures say little about the PR.
function unreliable_packages(dailies; window=Day(30), min_tests=5, min_failure_ratio=0.75)
    since = Date(now(UTC)) - window
    history = Dict{String,Vector{Tuple{Union{Nothing,VersionNumber},Bool}}}()
    for daily in dailies
        daily.date >= since || continue
        for (pkg, test) in daily.tests
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
