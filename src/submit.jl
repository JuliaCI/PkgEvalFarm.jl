# Creating runs: turn a set of Configurations plus a package selection into queue jobs.

"""
    submit_run(ctx; configs, packages=String[], context=Dict(), submitter) -> run_id

Submit an evaluation run. With an empty `packages`, evaluates every registered package
whose latest version supports *all* configurations (like `PkgEval.evaluate` does);
this consults the registry locally, so submission machines need network access but no
sandbox support.
"""
function submit_run(ctx::FarmCtx; configs::Vector{PkgEval.Configuration},
                    packages::Vector{String}=String[],
                    context::Dict{String,Any}=Dict{String,Any}(),
                    submitter::AbstractString=worker_identity())
    if isempty(packages)
        pkgs = intersect([PkgEval.get_packages(cfg) for cfg in configs]...)
        # JLL wrappers are not worth testing (PkgEval.evaluate drops them too)
        packages = [pkg.name for pkg in pkgs if !endswith(pkg.name, "_jll")]
    end
    isempty(packages) && error("no packages to evaluate")
    spec = RunSpec(configs, packages, context)
    run_id = create_run(ctx, spec; submitter)
    @info "submitted run" run_id configs=join([c.name for c in configs], ", ") npackages=length(packages)
    return run_id
end

"""
    build_configs(primary; against=nothing, buildflags=String[]) -> Vector{Configuration}

Turn Julia version specs (a version number, release name, `"nightly"`, or repo spec
like `"JuliaLang/julia#sha"`) into named configurations. With `against`, produces the
usual primary/against pair for comparison runs.
"""
function build_configs(primary::AbstractString; against::Union{AbstractString,Nothing}=nothing,
                       buildflags::Vector{String}=String[])
    kwargs = isempty(buildflags) ? (;) : (; buildflags)
    configs = [PkgEval.Configuration(; name="primary", julia=String(primary), kwargs...)]
    against === nothing ||
        push!(configs, PkgEval.Configuration(; name="against", julia=String(against), kwargs...))
    return configs
end

"Human-oriented progress summary of a run."
function run_status(ctx::FarmCtx, run_id::AbstractString)
    run = get_run(ctx, run_id)
    (; run_id, status=run["status"], completed=run["completed_jobs"],
       total=run["total_jobs"], submitter=run["submitter"], created_at=run["created_at"])
end
