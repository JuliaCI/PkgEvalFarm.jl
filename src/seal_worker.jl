# Worker-side sealing (docs/sealing.md): executing seal jobs, gating test jobs
# on them (hold-and-fill), and materializing sealed depots.
#
# There is deliberately no on-demand (filesystem-level) artifact layer: a
# cache-dir miss carries no resolution context — no version, dep build_ids or
# preferences — so nothing behind a filesystem interface can produce the
# *right* artifact, only serve already-published ones. Demand-driven
# generation needs the resolver's view, i.e. the future Pkg client protocol.
# The dynamic tail (runtime Pkg.add etc.) therefore compiles locally, exactly
# as it does today, and learned edges fold it into the static closure over
# successive runs.

is_seal_job(job::JobRef) = startswith(job.run_id, "seal-")
seal_id_of(run_id::AbstractString) = String(chopprefix(run_id, "seal-"))

"How long a gated test job waits (filling the time with seal work) before
running cold. Cold is soft — whatever sealed by then is still consumed — so
this trades duplicate compilation against latency, nothing more."
seal_wait_limit() = something(tryparse(Float64, get(ENV, "PKGEVAL_SEAL_WAIT", "")), 20.0 * 60)

"In-sandbox mount point of the materialized sealed depot. A constant: it
appears in JULIA_DEPOT_PATH inside sandboxes."
const SEALED_DEPOT_MOUNT = "/opt/pkgeval-sealed"

"""
Prepare the evaluation kwargs that give a job read-only access to sealed
artifacts: a per-job plain directory (hardlinks into the local cache) with the
package's published closure, mounted read-only and appended to the sandbox
depot path (via PKGEVAL_EXTRA_DEPOTS, understood by the PkgEval fork).

Returns `(kwargs, cleanup)`; call `cleanup()` after the evaluation.
"""
function sealed_depot_kwargs(ctx::FarmCtx, seal_id::AbstractString, packages)
    pkgeval_supports_seal() || return (;), Returns(nothing)
    if protocol_scheme()
        # the sandbox fetches through the loopback proxy on demand (needs the
        # julia-under-test to carry Base.CACHE_FETCH_HOOK; without it the env
        # vars are inert and the job just runs cold)
        proxy = SEAL_PROXY[]
        proxy === nothing && return (;), Returns(nothing)
        return (; env=Dict("PKGEVAL_CACHE_SERVER" => "http://127.0.0.1:$(proxy.port)",
                           "PKGEVAL_CACHE_NAMESPACE" => String(seal_id))), Returns(nothing)
    end
    depot = mktempdir(prefix="pkgeval_sealed_depot_")
    try
        files, _ = sealed_closure!(ctx, seal_id, packages)
        materialize_sealed_depot(seal_id, files, depot)
    catch err
        @warn "failed to materialize sealed depot; evaluating cold" seal_id err
    end
    kwargs = (; mounts=Dict("$SEALED_DEPOT_MOUNT:ro" => depot),
              env=Dict("PKGEVAL_EXTRA_DEPOTS" => SEALED_DEPOT_MOUNT))
    return kwargs, () -> rm(depot; recursive=true, force=true)
end


## seal-job execution

function process_seal_job(ctx::FarmCtx, claimed::ClaimedJob, cpu::Int,
                          run_cache, run_cache_lock)
    job = claimed.job
    seal_id = seal_id_of(job.run_id)
    @info "sealing" job.run_id job.package attempt=claimed.attempts slot=cpu
    stop_heartbeat = start_heartbeat(ctx, claimed, "seal $(job.package)")

    result = try
        config = job_config(ctx, job, run_cache, run_cache_lock)
        # rr instruments test execution; sealing has none, so always disable it
        config = PkgEval.Configuration(config; cpus=[cpu], goal=:seal, rr=PkgEval.RRDisabled)
        item = get_seal_item(ctx, job)
        deps = item === nothing ? String[] : String.(get(item, "deps", String[]))

        scratch = mktempdir(prefix="pkgeval_seal_")
        try
            export_dir = joinpath(scratch, "export")
            mkpath(export_dir)
            indexes = Dict{String,Any}()
            eval_kwargs = if protocol_scheme()
                # deps arrive on demand through the proxy; publication happens
                # below, namespaced by the registry
                kwargs, _ = sealed_depot_kwargs(ctx, seal_id, deps)
                kwargs
            else
                # pull-before-compile: canonical dep artifacts in a read-only
                # depot mean the produced cachefiles link against the
                # published files
                depot = joinpath(scratch, "depot")
                indexes = try
                    # all_versions: X's compat may resolve deps to versions
                    # other than the ones their own seal jobs sealed; any
                    # published variant is canonical and reusable
                    files, indexes = sealed_closure!(ctx, seal_id, deps; all_versions=true)
                    materialize_sealed_depot(seal_id, files, depot)
                    indexes
                catch err
                    @warn "dep closure fetch failed; sealing cold" job.package err
                    Dict{String,Any}()
                end
                (; mounts=Dict("$SEALED_DEPOT_MOUNT:ro" => depot),
                   env=Dict("PKGEVAL_EXTRA_DEPOTS" => SEALED_DEPOT_MOUNT))
            end

            r = PkgEval.evaluate_seal(config, PkgEval.Package(; name=job.package);
                                      use_cache=claimed.attempts <= 1,
                                      export_dir, eval_kwargs...)
            log = r.log === missing ? "" : String(r.log)
            if String(r.status) == "seal"
                graph, files_by_pkg = parse_seal_export(export_dir)
                if protocol_scheme()
                    unit_uuid = try
                        registry_uuid(seal_registry_dir(config), job.package)
                    catch err
                        @warn "could not resolve unit uuid from the registry" job.package err
                        nothing
                    end
                    published = unit_uuid !== nothing &&
                        publish_protocol!(ctx, seal_id, export_dir, job.package, unit_uuid)
                    log *= published ? "\n\nPublished the unit's cachefile pair" :
                                       "\n\nNothing published for the unit"
                else
                    dep_files = Dict{String,Vector{String}}(
                        pkg => String.(idx["files"]) for (pkg, idx) in indexes)
                    published, tainted = publish_sealed!(ctx, seal_id,
                        joinpath(export_dir, "compiled"), files_by_pkg, graph, dep_files)
                    log *= "\n\nSealed $(length(published)) package(s)" *
                           (isempty(tainted) ? "" :
                            "; lost publication races for: $(join(tainted, ", "))")
                end
                record_learned_edges(ctx, job.package, get(graph, job.package, String[]))
                JobResult(; status="sealed", version=r.version === missing ? nothing : string(r.version),
                          duration=Float64(r.duration), log)
            else
                JobResult(; status="unsealable",
                          reason=r.reason === missing ? nothing : String(r.reason),
                          version=r.version === missing ? nothing : string(r.version),
                          duration=Float64(r.duration), log)
            end
        finally
            try
                rm(scratch; recursive=true, force=true)
            catch err
                @warn "failed to clean seal scratch" err
            end
        end
    catch err
        if claimed.attempts >= 3
            @error "seal job errored repeatedly; recording unsealable" job.package exception=(err, catch_backtrace())
            JobResult(; status="error", reason="worker_exception",
                      log=sprint(showerror, err, catch_backtrace()))
        else
            @error "seal job errored; releasing for retry" job.package exception=(err, catch_backtrace())
            release_job(ctx, claimed)
            return
        end
    finally
        stop_heartbeat()
    end

    try
        record_result(ctx, claimed, result)
        @info "sealed" job.package result.status
    catch err
        @error "failed to record seal result; job will be retried" job.package exception=(err, catch_backtrace())
        release_job(ctx, claimed)
        return
    end

    # propagate readiness — re-reading dependents *after* the terminal write so
    # dependents appended by a concurrent expansion are still decremented
    try
        item = get_seal_item(ctx, job)
        dependents = item === nothing ? String[] :
                     unique(String.(get(item, "dependents", String[])))
        isempty(dependents) || propagate_seal_completion(ctx, job.run_id, dependents)
    catch err
        @warn "seal propagation failed; reconciliation will heal" job.package err
    end
    return
end

"Parse a seal evaluation's export: the resolved dependency graph (TOML written
in-sandbox) and the produced cachefiles grouped by the package dir they sit in."
function parse_seal_export(export_dir::AbstractString)
    graph = Dict{String,Vector{String}}()
    graph_file = joinpath(export_dir, "seal_graph.toml")
    if isfile(graph_file)
        for (pkg, info) in TOML.parsefile(graph_file)
            graph[pkg] = info isa AbstractDict ? String.(get(info, "deps", String[])) : String[]
        end
    end
    files_by_pkg = Dict{String,Vector{String}}()
    compiled = joinpath(export_dir, "compiled")
    if isdir(compiled)
        for vdir in readdir(compiled)
            isdir(joinpath(compiled, vdir)) || continue
            for pkg in readdir(joinpath(compiled, vdir))
                pkgdir = joinpath(compiled, vdir, pkg)
                isdir(pkgdir) || continue
                rels = [joinpath(vdir, pkg, f) for f in readdir(pkgdir)
                        if isfile(joinpath(pkgdir, f))]
                isempty(rels) || append!(get!(Vector{String}, files_by_pkg, pkg), rels)
            end
        end
    end
    return graph, files_by_pkg
end


## the test-job gate: hold the claim, fill the wait with seal work

"""
    hold_and_fill!(ctx, job, seal_run_id, cpu, run_cache, run_cache_lock) -> :terminal | :pending

The claimed test job stays held (its heartbeat keeps running); this slot pulls
seal jobs while `seal(X)` is pending. An empty seal queue while still gated is
the cue to (throttled) reconcile — the waiting party heals the pipeline it
waits on — and then to briefly idle: the wanted seal is in flight elsewhere.
`:pending` on return means the deadline passed — run cold.
"""
function hold_and_fill!(ctx::FarmCtx, job::JobRef, seal_run_id::AbstractString, cpu::Int,
                        run_cache, run_cache_lock)
    deadline = time() + seal_wait_limit()
    @info "test job gated on sealing; filling the wait" job.package seal_run_id
    while time() < deadline
        filled = try
            claim_seal_job(ctx)
        catch err
            @warn "seal queue poll failed" err
            nothing
        end
        if filled isa ClaimedJob
            process_seal_job(ctx, filled, cpu, run_cache, run_cache_lock)
        else
            maybe_reconcile_seal_run(ctx, seal_run_id)
            sleep(15)
        end
        seal_status(ctx, seal_run_id, job.package) == :pending || return :terminal
    end
    @info "seal wait deadline reached; evaluating with whatever sealed" job.package
    return :pending
end
