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

"""
    web_submit_url(primary; against, packages, assertions, fresh_baseline, request, broker)
        -> (; url, run_id)

A link that submits this run once a person opens it, signs in with GitHub and
confirms it on the broker's review page (`/submit`; JuliaLang members, as for
`farm submit`). Making the link needs no farm credentials, so tools without a farm
login — AI agents in sandboxes, scripts — can hand it to a person instead. The run
id is fixed by `request`, so a repeated click submits nothing new.
"""
function web_submit_url(primary::AbstractString;
                        against::Union{AbstractString,Nothing}=nothing,
                        packages::Vector{String}=String[], assertions::Bool=false,
                        fresh_baseline::Bool=false,
                        request::AbstractString=bytes2hex(rand(RandomDevice(), UInt8, 12)),
                        broker::AbstractString=broker_url())
    esc = HTTP.URIs.escapeuri
    parts = ["primary=" * esc(primary)]
    against === nothing || push!(parts, "against=" * esc(against))
    isempty(packages) || push!(parts, "packages=" * esc(join(packages, ",")))
    assertions && push!(parts, "assertions=true")
    fresh_baseline && push!(parts, "fresh_baseline=true")
    push!(parts, "request=" * esc(request))
    url = joinpath_url(broker, "submit") * "?" * join(parts, "&")
    # the broker carries the spec through GitHub sign-in in URLs, which CloudFront
    # limits to 8 KiB; it refuses links whose longest leg would not fit
    ncodeunits(url) <= 6000 ||
        error("this run is too large for a web submission link ($(length(packages)) packages); " *
              "name fewer packages, or test all of them by naming none")
    return (; url, run_id="web-" * request)
end
