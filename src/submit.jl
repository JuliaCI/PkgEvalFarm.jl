# Creating runs: turn a set of Configurations plus a package selection into queue jobs.

"""
    submit_run(ctx; configs, packages=String[], context=Dict(), submitter) -> run_id

Submit an evaluation run. With an empty `packages`, every registered package whose
latest version supports *all* configurations is evaluated; that selection is computed
on a worker (via an expand job), since it may require the Julia build under test.
"""
function submit_run(ctx::FarmCtx; configs::Vector{PkgEval.Configuration},
                    packages::Vector{String}=String[],
                    context::Dict{String,Any}=Dict{String,Any}(),
                    submitter::AbstractString=worker_identity(),
                    reuse::Bool=true)
    spec = RunSpec(configs, packages, context)
    run_id = create_run(ctx, spec; submitter, reuse)
    @info "submitted run" run_id configs=join([c.name for c in configs], ", ") packages=(isempty(packages) ? "all (worker-expanded)" : string(length(packages)))
    return run_id
end

const UPSTREAM_JULIA = "JuliaLang/julia"

function github_api_get(path::AbstractString)
    headers = ["Accept" => "application/vnd.github+json"]
    token = get(ENV, "GITHUB_AUTH", "")
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    resp = HTTP.get("https://api.github.com" * path, headers; status_exception=false)
    resp.status == 200 ||
        error("GitHub API request for $path failed (HTTP $(resp.status)): $(String(resp.body))")
    return JSON.parse(String(resp.body))
end

"""
    canonicalize_julia_spec(spec) -> String

Rewrite a repo spec naming a branch, tag or commit of a *fork* of JuliaLang/julia
(`"Owner/julia#branch"`) into `"JuliaLang/julia#<sha>"`. Workers only install
JuliaLang/julia builds, and CI builds any commit of the fork network under that name,
so this is what lets a run evaluate work that was only pushed to a fork. Other specs
are returned unchanged.
"""
function canonicalize_julia_spec(spec::AbstractString)
    occursin('#', spec) || return String(spec)
    repo, ref = PkgEval.parse_repo_spec(spec)
    repo == UPSTREAM_JULIA && return String(spec)
    info = github_api_get("/repos/$repo")
    source = get(get(info, "source", Dict()), "full_name", nothing)
    source == UPSTREAM_JULIA ||
        error("$repo is not a fork of $UPSTREAM_JULIA; only its fork network can be built")
    sha = lowercase(github_api_get("/repos/$repo/commits/$(HTTP.URIs.escapeuri(ref))")["sha"])
    @info "resolved fork spec" spec sha
    return "$UPSTREAM_JULIA#$sha"
end

"""
    build_configs(primary; against=nothing, buildflags=String[]) -> Vector{Configuration}

Turn Julia version specs (a version number, release name, `"nightly"`, or repo spec
like `"JuliaLang/julia#sha"` or `"Owner/julia#branch"` for a fork) into named
configurations. With `against`, produces the usual primary/against pair for comparison
runs.
"""
function build_configs(primary::AbstractString; against::Union{AbstractString,Nothing}=nothing,
                       buildflags::Vector{String}=String[])
    kwargs = isempty(buildflags) ? (;) : (; buildflags)
    primary = canonicalize_julia_spec(primary)
    configs = [PkgEval.Configuration(; name="primary", julia=primary, kwargs...)]
    if against !== nothing
        against = canonicalize_julia_spec(against)
        push!(configs, PkgEval.Configuration(; name="against", julia=against, kwargs...))
    end
    return configs
end

"Human-oriented progress summary of a run."
function run_status(ctx::FarmCtx, run_id::AbstractString)
    run = get_run(ctx, run_id)
    (; run_id, status=run["status"], completed=run["completed_jobs"],
       total=run["total_jobs"], submitter=run["submitter"], created_at=run["created_at"])
end
