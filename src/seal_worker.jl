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
is_derivation_job(job::JobRef) = startswith(job.run_id, "deriv-")
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
function sealed_depot_kwargs(ctx::FarmCtx, seal_id::AbstractString, packages;
                             scheme::AbstractString="depot")
    pkgeval_supports_seal() || return (;), Returns(nothing)
    if scheme == "protocol"
        # the sandbox fetches through the loopback proxy on demand; the
        # expansion-side detection guarantees this julia carries the hook
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
        seal_run = job_run(ctx, job, run_cache, run_cache_lock)
        scheme = seal_run_scheme(seal_run)
        protocol = scheme == "protocol"
        config = job_config(ctx, job, run_cache, run_cache_lock)
        # rr instruments test execution; sealing has none, so always disable it
        config = PkgEval.Configuration(config; cpus=[cpu], goal=:seal, rr=PkgEval.RRDisabled)
        item = get_seal_item(ctx, job)
        deps = item === nothing ? String[] : String.(get(item, "deps", String[]))

        eval_started = time()
        scratch = mktempdir(prefix="pkgeval_seal_")
        try
            export_dir = joinpath(scratch, "export")
            mkpath(export_dir)
            indexes = Dict{String,Any}()
            eval_kwargs = if protocol
                # deps arrive on demand through the proxy; publication happens
                # below, namespaced by the registry
                kwargs, _ = sealed_depot_kwargs(ctx, seal_id, deps; scheme)
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
                if protocol
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
                          duration=Float64(r.duration), wall=time() - eval_started, log)
            else
                JobResult(; status="unsealable",
                          reason=r.reason === missing ? nothing : String(r.reason),
                          version=r.version === missing ? nothing : string(r.version),
                          duration=Float64(r.duration), wall=time() - eval_started, log)
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

## derivation execution (docs/sealing.md, stage 2)

"""
    fetch_derivation_closure(ctx, ns, roots) -> (artifacts, pins, missing)

Resolve a derivation's dependency closure by key: BFS from the want's direct
deps through each artifact's `.meta` sidecar. `artifacts` is `(meta, blob)`
pairs ready to materialize; `pins` maps uuid to name/version for the
whole-environment pin; `missing` lists unfetchable keys (unkeyable "-" deps
are skipped — stdlibs live in the julia build itself).
"""
function fetch_derivation_closure(ctx::FarmCtx, ns::AbstractString, roots)
    seen = Set{String}()
    artifacts = Tuple{Dict{String,Any},Vector{UInt8}}[]
    pins = Dict{String,Any}()
    missing_keys = String[]
    queue = [(String(uuid), String(key)) for (uuid, key) in roots]
    while !isempty(queue)
        uuid, key = popfirst!(queue)
        (key == "-" || key in seen) && continue
        push!(seen, key)
        meta_body = get_kv(ctx, ns, uuid, key; meta=true)
        blob = get_kv(ctx, ns, uuid, key)
        if meta_body === nothing || blob === nothing
            push!(missing_keys, key)
            continue
        end
        meta = try
            JSON.parse(String(meta_body))
        catch
            push!(missing_keys, key)
            continue
        end
        push!(artifacts, (meta, blob))
        version = String(get(meta, "version", "-"))
        if version != "-"
            pins[uuid] = Dict("name" => String(meta["name"]), "uuid" => uuid,
                              "version" => version)
        end
        for d in get(meta, "deps", Any[])
            d isa AbstractDict || continue
            push!(queue, (lowercase(String(get(d, "uuid", ""))), String(get(d, "key", "-"))))
        end
    end
    return artifacts, pins, missing_keys
end

"Unpack fetched artifacts into a depot at the filenames their producers used."
function materialize_derivation_depot(artifacts, depot::AbstractString)
    # even with nothing to place (leaf package, or deps still in flight) the
    # depot must exist: it becomes a bind-mount source, and mounting a
    # nonexistent path crashed 162 derivations in the first fixed-pins run
    mkpath(depot)
    n = 0
    for (meta, blob) in artifacts
        pair = unframe_pair(blob)
        pair === nothing && continue
        ji, so = pair
        dir = joinpath(depot, "compiled", String(meta["vdir"]), String(meta["name"]))
        mkpath(dir)
        write(joinpath(dir, String(meta["ji"])), ji)
        so_name = String(get(meta, "so", ""))
        !isempty(so_name) && !isempty(so) && write(joinpath(dir, so_name), so)
        n += 1
    end
    return n
end

function process_derivation_job(ctx::FarmCtx, claimed::ClaimedJob, cpu::Int,
                                run_cache, run_cache_lock)
    job = claimed.job
    ns = String(chopprefix(job.run_id, "deriv-"))
    stop_heartbeat = start_heartbeat(ctx, claimed, "derive $(first(job.package, 12))")
    @info "deriving" ns key=first(job.package, 12) attempt=claimed.attempts slot=cpu

    result = try
        item = get_seal_item(ctx, job)
        want = item === nothing ? nothing :
               parse_want_preimage(String(get(item, "preimage", "")))
        if want === nothing || !isdefined(PkgEval, :evaluate_derive)
            JobResult(; status="unsealable", reason="worker_exception",
                      log="derivation item unreadable, or PkgEval lacks evaluate_derive")
        else
            # the julia/flags context comes from the namespace's seal run — the
            # trusted record of what this fingerprint means
            seal_run = job_run(ctx, JobRef(seal_run_id(ns), SEAL_CONFIG_NAME, ""),
                               run_cache, run_cache_lock)
            config = config_from_dict(only(seal_run["configs"]))
            config = PkgEval.Configuration(config; cpus=[cpu], rr=PkgEval.RRDisabled)

            eval_started = time()
            scratch = mktempdir(prefix="pkgeval_derive_")
            try
                roots = [(d.uuid, d.key) for d in want.deps]
                artifacts, pins, missing_keys = fetch_derivation_closure(ctx, ns, roots)
                # Not-yet-published deps are NOT a decline: the sandbox fetches
                # them through the proxy, which holds each request while that
                # key's derivation is in flight (dataflow ordering by blocking;
                # the slot meanwhile donates, see maybe_donate!). Deps the want
                # names still get version-pinned so resolution stays exact even
                # before their artifacts land.
                is_ext = want.ext_of !== nothing
                merge_want_pins!(pins, want; include_unversioned=is_ext)
                isempty(missing_keys) ||
                    @info "deriving with deps in flight" key=first(job.package, 12) nmissing=length(missing_keys)
                begin
                    depot = joinpath(scratch, "depot")
                    materialize_derivation_depot(artifacts, depot)
                    pins_file = joinpath(scratch, "derive_pins.toml")
                    open(pins_file, "w") do io
                        TOML.print(io, pins)
                    end
                    export_dir = joinpath(scratch, "export")
                    mkpath(export_dir)
                    r = PkgEval.evaluate_derive(config,
                            PkgEval.Package(; name=want.name,
                                            uuid=UUID(want.uuid),
                                            version=VersionNumber(want.version));
                            use_cache=claimed.attempts <= 1, export_dir, pins_file,
                            mounts=Dict("$SEALED_DEPOT_MOUNT:ro" => depot),
                            env=Dict("PKGEVAL_EXTRA_DEPOTS" => SEALED_DEPOT_MOUNT,
                                     "PKGEVAL_CACHE_SERVER" => proxy_url(),
                                     "PKGEVAL_CACHE_NAMESPACE" => ns,
                                     # no fetch hook: everything published is
                                     # already in the depot, and holding on an
                                     # unpublished key deadlocks the derivation
                                     # against itself (seen live: TestEnv derive
                                     # + 5 test jobs all inactivity-killed)
                                     "PKGEVAL_CACHE_FETCH" => "0",
                                     # extension unit: install pins only; the
                                     # ext compiles once parent+triggers land
                                     "PKGEVAL_DERIVE_EXT" => is_ext ? "1" : "0"))
                    log = r.log === missing ? "" : String(r.log)
                    if String(r.status) == "derive"
                        unit_uuid = if is_ext
                            # the loader's uuid5 varies with the julia's hash,
                            # so the host can't recompute it: authority is the
                            # key binding the full preimage, guarded by parse's
                            # shape check plus (here) a registry parent and no
                            # collision with any registry package's namespace
                            reg = seal_registry_dir(config)
                            registry_has_uuid(reg, want.ext_of) &&
                                !registry_has_uuid(reg, want.uuid) ? want.uuid : nothing
                        else
                            try
                                registry_uuid(seal_registry_dir(config), want.name)
                            catch err
                                @warn "could not resolve unit uuid" want.name err
                                nothing
                            end
                        end
                        produced = produced_key(export_dir, want.name)
                        published = unit_uuid !== nothing &&
                            publish_protocol!(ctx, ns, export_dir, want.name, unit_uuid)
                        log *= "\n\nDerivation " *
                               (produced == job.package ? "matched the wanted key" :
                                "produced a different key (" * first(something(produced, "none"), 12) *
                                "); environment reproduction was inexact") *
                               (published ? "; published" : "; nothing published")
                        JobResult(; status="sealed", duration=Float64(r.duration),
                                  wall=time() - eval_started, log)
                    else
                        JobResult(; status="unsealable",
                                  reason=r.reason === missing ? nothing : String(r.reason),
                                  duration=Float64(r.duration),
                                  wall=time() - eval_started, log)
                    end
                end
            finally
                try
                    rm(scratch; recursive=true, force=true)
                catch err
                    @warn "failed to clean derivation scratch" err
                end
            end
        end
    catch err
        if claimed.attempts >= 3
            @error "derivation errored repeatedly; recording unsealable" exception=(err, catch_backtrace())
            JobResult(; status="error", reason="worker_exception",
                      log=sprint(showerror, err, catch_backtrace()))
        else
            @error "derivation errored; releasing for retry" exception=(err, catch_backtrace())
            release_job(ctx, claimed)
            return
        end
    finally
        stop_heartbeat()
    end

    try
        record_result(ctx, claimed, result)
        @info "derivation finished" key=first(job.package, 12) result.status
    catch err
        @error "failed to record derivation result" exception=(err, catch_backtrace())
        release_job(ctx, claimed)
    end
    return
end

"""
Version-pin a want's direct deps into `pins` (uuid keyed). Want dep lines
carry no package *name* — PackageSpec pins fine on uuid+version alone —
and unkeyable deps (version "-": stdlibs, dev) are not pinnable. For an
extension want they are still *required* (a stdlib trigger must be a direct
dep for the extension to build), so `include_unversioned` records them as
uuid-only entries.
"""
function merge_want_pins!(pins::AbstractDict, want; include_unversioned::Bool=false)
    for d in want.deps
        haskey(pins, d.uuid) && continue
        if d.version == "-"
            include_unversioned || continue
            pins[d.uuid] = Dict("uuid" => d.uuid)
        else
            pins[d.uuid] = Dict("uuid" => d.uuid, "version" => d.version)
        end
    end
    return pins
end

"The unit's produced key from a derivation/seal export, or `nothing`."
function produced_key(export_dir::AbstractString, unit::AbstractString)
    keys_file = joinpath(export_dir, "seal_keys.toml")
    isfile(keys_file) || return nothing
    entry = try
        get(TOML.parsefile(keys_file), unit, nothing)
    catch
        nothing
    end
    entry isa AbstractDict ? String(get(entry, "key", "")) : nothing
end

"The running proxy's base URL (empty when the proxy is down — the client
degrades to misses)."
function proxy_url()
    proxy = SEAL_PROXY[]
    proxy === nothing ? "" : "http://127.0.0.1:$(proxy.port)"
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
            # the seal queue carries seal AND derivation messages: dispatch
            # like the main claim path does, or a filled derivation crashes in
            # seal processing (seen live: 66 error'd derivations, trial run 1)
            process_job(ctx, filled, cpu, run_cache, run_cache_lock)
        else
            maybe_reconcile_seal_run(ctx, seal_run_id)
            sleep(15)
        end
        seal_status(ctx, seal_run_id, job.package) == :pending || return :terminal
    end
    @info "seal wait deadline reached; evaluating with whatever sealed" job.package
    return :pending
end
