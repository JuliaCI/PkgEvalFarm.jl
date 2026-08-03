# Worker-side sealing (docs/sealing.md): executing seal jobs, gating test jobs
# on them (hold-and-fill), and executing derivations.
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

"""
Evaluation kwargs pointing a job's sandbox at the cache protocol: the loopback
proxy address and its namespace. Empty when the proxy isn't running.
"""
function seal_protocol_kwargs(seal_id::AbstractString)
    pkgeval_supports_seal() || return (;)
    # the expansion-side detection guarantees this julia carries the hook
    proxy = SEAL_PROXY[]
    proxy === nothing && return (;)
    env = Dict("PKGEVAL_CACHE_SERVER" => "http://127.0.0.1:$(proxy.port)",
               "PKGEVAL_CACHE_NAMESPACE" => String(seal_id))
    # e.g. PKGEVAL_JULIA_DEBUG=loading: surface the loader's cachefile
    # rejection reasons in job logs when chasing convergence bugs
    dbg = get(ENV, "PKGEVAL_JULIA_DEBUG", "")
    isempty(dbg) || (env["JULIA_DEBUG"] = dbg)
    haskey(ENV, "JULIA_CACHE_HOOK_TRACE") && (env["JULIA_CACHE_HOOK_TRACE"] = "1")
    return (; env)
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

        eval_started = time()
        scratch = mktempdir(prefix="pkgeval_seal_")
        try
            export_dir = joinpath(scratch, "export")
            mkpath(export_dir)
            # deps arrive on demand through the proxy; publication happens
            # below, namespaced by the registry
            eval_kwargs = seal_protocol_kwargs(seal_id)

            r = PkgEval.evaluate_seal(config, PkgEval.Package(; name=job.package);
                                      use_cache=claimed.attempts <= 1,
                                      export_dir, eval_kwargs...)
            log = r.log === missing ? "" : String(r.log)
            if String(r.status) == "seal"
                graph, _ = parse_seal_export(export_dir)
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
    derivation_pins(ctx, ns, roots) -> (pins, missing)

Walk a derivation's dependency closure by key — BFS from the want's direct
deps through each artifact's `.meta` sidecar — collecting `pins` (uuid to
name/version, for the whole-environment pin). `missing` lists unfetchable
keys (unkeyable "-" deps are skipped — stdlibs live in the julia build
itself). Artifacts themselves arrive in-sandbox through the nohold probe.
"""
function derivation_pins(ctx::FarmCtx, ns::AbstractString, roots)
    seen = Set{String}()
    pins = Dict{String,Any}()
    missing_keys = String[]
    queue = [(String(uuid), String(key)) for (uuid, key) in roots]
    while !isempty(queue)
        uuid, key = popfirst!(queue)
        (key == "-" || key in seen) && continue
        push!(seen, key)
        meta_body = get_kv(ctx, ns, uuid, key; meta=true)
        if meta_body === nothing
            push!(missing_keys, key)
            continue
        end
        meta = try
            JSON.parse(String(meta_body))
        catch
            push!(missing_keys, key)
            continue
        end
        version = String(get(meta, "version", "-"))
        # extensions are never Pkg-addable: pinning one fails resolution
        # outright ("expected package to be registered"); their meta carries
        # the parent's version, so the version check alone does not exclude
        # them
        is_ext_meta = !isempty(String(get(meta, "ext_of", "")))
        if version != "-" && !is_ext_meta
            pins[uuid] = Dict("name" => String(meta["name"]), "uuid" => uuid,
                              "version" => version)
        end
        for d in get(meta, "deps", Any[])
            d isa AbstractDict || continue
            push!(queue, (lowercase(String(get(d, "uuid", ""))), String(get(d, "key", "-"))))
        end
    end
    return pins, missing_keys
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
                pins, missing_keys = derivation_pins(ctx, ns, roots)
                # Not-yet-published deps are NOT a decline: the derivation
                # compiles them locally (the nohold probe below 404s) and its
                # produced key is simply inexact until a later pass re-derives
                # against the published set. Deps the want names still get
                # version-pinned so resolution stays exact regardless.
                is_ext = want.ext_of !== nothing
                merge_want_pins!(pins, want; include_unversioned=is_ext)
                isempty(missing_keys) ||
                    @info "deriving with deps in flight" key=first(job.package, 12) nmissing=length(missing_keys)
                begin
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
                            env=Dict("PKGEVAL_CACHE_SERVER" => proxy_url(),
                                     "PKGEVAL_CACHE_NAMESPACE" => ns,
                                     # probe-only fetch: canonical deps come
                                     # from the store, so the produced preimage
                                     # carries the build_ids consumers want —
                                     # but nothing ever holds: holding on an
                                     # unpublished key deadlocks the derivation
                                     # against itself (seen live: TestEnv
                                     # derive + 5 test jobs inactivity-killed)
                                     "PKGEVAL_CACHE_NOHOLD" => "1",
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
            # implied-extension dep lines are unversioned like stdlib triggers
            # but are never Pkg-addable; their uuid5 shape tells them apart
            # (they reach the derive env via the nohold fetch instead)
            is_uuid5_shaped(d.uuid) && continue
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
