# Sealed compilecache: producing, publishing and consuming precompilation
# artifacts shared across the fleet. See docs/sealing.md for the design.
#
# Invariants this file maintains:
#  - S3 objects under compilecache/ are create-only (If-None-Match: *) and
#    therefore immutable: first writer wins, racing publishers lose quietly.
#  - The dependency graph is advisory. Nothing here is load-bearing for
#    correctness — Julia's loader validates every cache candidate, and a seal
#    job compiles locally whatever it cannot reuse. Counters, learned edges and
#    reconciliation only exist to make duplicate cold compiles rare.

export seal_fingerprint

"Config name reserved for seal jobs (their job_key is `seal#<package>`)."
const SEAL_CONFIG_NAME = "seal"

"Jobs-table partition holding observed package->deps edges from resolved manifests."
const LEARNED_EDGES_RUN = "_learned-edges"

seal_terminal(status::AbstractString) = status in ("sealed", "unsealable", "error")

"""
Fingerprint of the configuration fields that affect compilecache validity.
Scheduling- and observation-only fields must not fragment the cache: two
configs differing only in time limits share every artifact. The denylist is
conservative the safe way — an over-included field only costs sharing, an
excluded one costs nothing (the loader rejects mismatched candidates itself).
"""
function seal_fingerprint(config_dict::AbstractDict)
    irrelevant = ("name", "cpus", "time_limit", "memory_limit", "log_limit",
                  "rr", "goal", "precompile", "compile_time_limit")
    relevant = Dict(k => v for (k, v) in config_dict if String(k) ∉ irrelevant)
    return first(config_fingerprint(relevant), 16)
end

seal_run_id(fingerprint::AbstractString) = "seal-" * fingerprint

sealing_enabled(cfg::FarmConfig) = !isempty(cfg.seal_queue_url)


## S3 layout
#
# compilecache/<ns>/kv/<uuid>/<key>[.meta]   protocol artifacts (seal_proxy.jl)

is_not_found(err) = err isa AWS.AWSException &&
    (err.code in ("NoSuchKey", "NotFound", "404") ||
     (err.cause isa HTTP.StatusError && err.cause.status == 404))

"""
Create-only upload with a sha256 checksum attached. Returns `:created`,
`:exists_same`, `:exists_differs`, or `:exists_unknown` (the store did not
report a comparable checksum — treated as same by callers, since the only harm
of a wrong guess is publishing/skipping a subtree that another seal job covers
anyway).
"""
function put_sealed_object(ctx::FarmCtx, key::AbstractString, body::Vector{UInt8};
                           content_type="application/octet-stream", tags::AbstractString="")
    digest = SHA.sha256(body)
    headers = Dict{String,Any}("If-None-Match" => "*",
                               "x-amz-checksum-sha256" => Base64.base64encode(digest),
                               "Content-Type" => content_type)
    isempty(tags) || (headers["x-amz-tagging"] = tags)
    created = aws_retry() do
        try
            S3.put_object(ctx.cfg.bucket, key, Dict("body" => body, "headers" => headers);
                          aws_config=ctx.aws)
            true
        catch err
            # a lost first-writer race is an outcome, not a retryable error
            is_precondition_failed(err) ? false : rethrow()
        end
    end
    created && return :created
    # lost the race: is the existing object the same bytes?
    existing = try
        resp = S3.head_object(ctx.cfg.bucket, key,
                              Dict("headers" => Dict("x-amz-checksum-mode" => "ENABLED"));
                              aws_config=ctx.aws)
        get(resp, "x-amz-checksum-sha256", nothing)
    catch err
        is_not_found(err) ? nothing : rethrow()
    end
    existing === nothing && return :exists_unknown
    return String(existing) == Base64.base64encode(digest) ? :exists_same : :exists_differs
end

## the local artifact cache

seal_cache_root() = get(ENV, "PKGEVAL_SEAL_CACHE", joinpath(tempdir(), "pkgeval-seal-cache"))

"Drop cache entries untouched for `max_age` (default a week): PR-build seal ids
die with their runs, and the S3 side re-materializes anything evicted early."
function sweep_seal_cache!(; max_age::Real=7 * 24 * 3600)
    root = seal_cache_root()
    isdir(root) || return nothing
    cutoff = time() - max_age
    for id in readdir(root; join=true)
        try
            newest = maximum([mtime(f) for (dir, _, fs) in walkdir(id) for f in joinpath.(dir, fs)];
                             init=mtime(id))
            newest < cutoff && rm(id; recursive=true, force=true)
        catch err
            @warn "seal cache sweep failed for $id" err
        end
    end
    return nothing
end


## static dependency graph

"""
Direct-dependency graph from a registry checkout, restricted to `wanted`
package names: the union of every Deps.toml section, i.e. deliberately an
over-approximation across versions — the graph only schedules, it never gates
correctness (see docs/sealing.md).
"""
function registry_dep_graph(registry_dir::AbstractString, wanted::AbstractSet{String})
    registry = TOML.parsefile(joinpath(registry_dir, "Registry.toml"))
    graph = Dict{String,Vector{String}}()
    for (_, entry) in get(registry, "packages", Dict())
        name = entry["name"]
        name in wanted || continue
        deps_file = joinpath(registry_dir, entry["path"], "Deps.toml")
        deps = Set{String}()
        if isfile(deps_file)
            for (_, section) in TOML.parsefile(deps_file)
                section isa AbstractDict || continue
                for dep in keys(section)
                    dep in wanted && dep != name && push!(deps, dep)
                end
            end
        end
        graph[name] = sort!(collect(deps))
    end
    # packages absent from the registry (stdlib-adjacent oddities) become leaves
    for name in wanted
        haskey(graph, name) || (graph[name] = String[])
    end
    return graph
end

"Observed package->deps edges from previous runs' resolved manifests."
function learned_edges(ctx::FarmCtx)
    edges = Dict{String,Vector{String}}()
    for item in run_jobs(ctx, LEARNED_EDGES_RUN)
        deps = get(item, "deps", nothing)
        deps isa AbstractVector || continue
        edges[String(item["package"])] = String.(deps)
    end
    return edges
end

"Record the deps a seal job actually resolved (the learned-edge memo table)."
function record_learned_edges(ctx::FarmCtx, package::AbstractString, deps::Vector{String})
    isempty(deps) && return nothing
    try
        Dynamodb.update_item(
            ddb_item(Dict("run_id" => LEARNED_EDGES_RUN, "job_key" => String(package))),
            ctx.cfg.jobs_table,
            Dict("UpdateExpression" => "SET package = :pkg, deps = :deps, updated_at = :now",
                 "ExpressionAttributeValues" => ddb_item(Dict(
                     ":pkg" => String(package), ":deps" => sort(deps), ":now" => isodate())));
            aws_config=ctx.aws)
    catch err
        @warn "failed to record learned edges" package err
    end
    return nothing
end

"Static graph for expansion: registry union-graph merged with learned edges
(both restricted to the run's package set)."
function seal_dep_graph(registry_dir::AbstractString, packages::Vector{String},
                        learned::AbstractDict=Dict{String,Vector{String}}())
    wanted = Set(packages)
    graph = registry_dep_graph(registry_dir, wanted)
    registry_edges = Dict(pkg => Set(deps) for (pkg, deps) in graph)
    for (pkg, deps) in learned
        pkg in wanted || continue
        merged = Set(graph[pkg])
        for d in deps
            d in wanted && d != pkg && push!(merged, d)
        end
        graph[pkg] = sort!(collect(merged))
    end
    # Cycles deadlock the readiness counters: every member waits on another
    # member, no completion ever decrements the component free, and everything
    # downstream of it freezes with it. They are routine, not exotic — the
    # registry union across version ranges and the learned test-dep edges both
    # create them (a Compat <-> SHA cycle froze ~78% of every ecosystem seal
    # run at the same ~2,650-job prefix, runs seal-42eec8/seal-0c7a5 et al.).
    # Untangling must preserve as much *order* as possible, not just break the
    # deadlock: a member sealed before its real deps compiles them cold, and a
    # cold-compiled dep bakes a sandbox-local build_id into every key the
    # member publishes — keys no consumer ever computes, so the seal is wasted
    # and a canonical-twin derivation (plus its first consumers' holds) must
    # redo the work. At ecosystem hubs (Compat), that convoy is expensive.
    #
    # Pass 1: inside a component, keep the registry's own edges and drop only
    # the learned ones — cycles are usually closed by a test-dep edge (A's
    # tests use B, B's tests use A), and load-time dependency graphs are
    # acyclic, so this usually recovers the true direction outright.
    comp = scc_ids(graph)
    for (pkg, deps) in graph
        graph[pkg] = [d for d in deps if get(comp, d, 0) != comp[pkg] ||
                                         d in registry_edges[pkg]]
    end
    # Pass 2: residual registry-level cycles (version-range unions) get a
    # deterministic orientation instead of a blind drop: members keep
    # intra-component deps only on lexicographically-earlier members, so the
    # component seals as a chain, each member consuming its predecessors'
    # published artifacts. Half the edges orient "right" instead of none.
    comp = scc_ids(graph)
    order = Dict{String,Int}()
    members = Dict{Int,Vector{String}}()
    for pkg in keys(graph)
        push!(get!(Vector{String}, members, comp[pkg]), pkg)
    end
    for pkgs in values(members)
        length(pkgs) >= 2 || continue
        for (i, pkg) in enumerate(sort!(pkgs))
            order[pkg] = i
        end
    end
    for (pkg, deps) in graph
        haskey(order, pkg) || continue
        graph[pkg] = [d for d in deps if get(comp, d, 0) != comp[pkg] ||
                                         order[d] < order[pkg]]
    end
    return graph
end

"""
Strongly-connected components of a `node -> deps` adjacency dict, as a
`node -> component id` map over the dict's keys. Deps that are not keys have
no recorded out-edges, so they can never sit on a cycle — callers treat them
as external (`get(comp, d, 0)`). Iterative Tarjan: the seal graph is
ecosystem-sized and recursion would overflow.
"""
function scc_ids(graph::AbstractDict)
    index = Dict{String,Int}()
    low = Dict{String,Int}()
    onstack = Set{String}()
    stack = String[]
    comp = Dict{String,Int}()
    next_index = 0
    next_comp = 0
    for start in keys(graph)
        haskey(index, start) && continue
        work = Tuple{String,Int}[(String(start), 0)]
        while !isempty(work)
            node, i = pop!(work)
            if i == 0
                next_index += 1
                index[node] = low[node] = next_index
                push!(stack, node)
                push!(onstack, node)
            end
            deps = get(graph, node, String[])
            recursed = false
            j = i
            while j < length(deps)
                j += 1
                d = String(deps[j])
                haskey(graph, d) || continue
                if !haskey(index, d)
                    push!(work, (node, j))   # resume after this dep
                    push!(work, (d, 0))
                    recursed = true
                    break
                elseif d in onstack
                    low[node] = min(low[node], index[d])
                end
            end
            recursed && continue
            if low[node] == index[node]
                next_comp += 1
                while true
                    w = pop!(stack)
                    delete!(onstack, w)
                    comp[w] = next_comp
                    w == node && break
                end
            end
            if !isempty(work)
                parent, _ = work[end]
                low[parent] = min(low[parent], low[node])
            end
        end
    end
    return comp
end


## seal runs and their jobs

"""
Idempotently create the shared seal run for a configuration. Seal runs carry
the reserved config name and an empty context, which the bot's delivery guards
already skip; they start `active` (there is no expand phase — jobs are added
directly, possibly across many user runs).
"""
function ensure_seal_run(ctx::FarmCtx, config_dict::AbstractDict, seal_id::AbstractString)
    run_id = seal_run_id(seal_id)
    seal_config = Dict{String,Any}(config_dict)
    seal_config["name"] = SEAL_CONFIG_NAME
    try
        Dynamodb.put_item(ddb_item(Dict(
                "run_id" => run_id,
                "created_at" => isodate(),
                "submitter" => "sealer",
                "status" => "active",
                "kind" => "seal",
                # recorded so gates can recognize (and run cold against) seal
                # runs from retired schemes instead of misreading them
                "scheme" => "protocol",
                "configs" => JSON.json([seal_config]),
                "packages" => "[]",
                "context" => JSON.json(Dict("seal" => true)),
                "total_jobs" => 0,
                "completed_jobs" => 0)), ctx.cfg.runs_table,
            Dict("ConditionExpression" => "attribute_not_exists(run_id)");
            aws_config=ctx.aws)
    catch err
        is_conditional_failure(err) || rethrow()
    end
    return run_id
end

"""
    add_seal_jobs(ctx, seal_run_id, packages, graph) -> (ncreated, ready)

Add seal jobs for `packages` that the (shared, possibly pre-existing) seal run
does not have yet, with dependency counters, and return the newly-ready ones.
Item creation is per-item conditional so concurrent expansions of runs sharing
a seal id cannot double-count `total_jobs`.

The decrement bookkeeping is deliberately best-effort (see file header): thin
races against concurrently-completing deps can decrement early (a job seals
with some deps cold — wasted warmth, not wrongness) or leave a counter stuck
(healed by `reconcile_seal_run`).
"""
function add_seal_jobs(ctx::FarmCtx, seal_run_id::AbstractString, packages::Vector{String},
                       graph::AbstractDict)
    existing = Dict{String,Tuple{String,Int}}()   # package -> (status, remaining)
    for item in run_jobs(ctx, seal_run_id)
        existing[String(item["package"])] =
            (String(get(item, "status", "pending")), Int(get(item, "remaining", 0)))
    end
    # already-ready jobs among our packages get (re-)enqueued too: an earlier
    # expansion may have died between creating them and sending their messages,
    # and duplicate messages are harmless while lost ones stall the pipeline
    requeue = [p for p in packages
               if haskey(existing, p) && existing[p] == ("pending", 0)]
    todo = [p for p in packages if !haskey(existing, p)]
    isempty(todo) && return 0, requeue
    todo_set = Set(todo)

    # dependents lists only need edges into *new* jobs: existing jobs' lists
    # already cover existing dependents
    dependents = Dict{String,Vector{String}}()
    for pkg in todo, dep in get(graph, pkg, String[])
        push!(get!(Vector{String}, dependents, dep), pkg)
    end

    nonterminal(dep) = dep in todo_set ||
        (haskey(existing, dep) && !seal_terminal(existing[dep][1]))
    created = String[]
    remaining_of = Dict{String,Int}()
    for pkg in todo
        deps = [d for d in get(graph, pkg, String[]) if d in todo_set || haskey(existing, d)]
        remaining = count(nonterminal, deps)
        remaining_of[pkg] = remaining
        try
            Dynamodb.put_item(ddb_item(Dict(
                    "run_id" => seal_run_id,
                    "job_key" => job_key(SEAL_CONFIG_NAME, pkg),
                    "config" => SEAL_CONFIG_NAME,
                    "package" => pkg,
                    "kind" => "seal",
                    "status" => "pending",
                    "attempts" => 0,
                    "deps" => deps,
                    "dependents" => get(dependents, pkg, String[]),
                    "remaining" => remaining)), ctx.cfg.jobs_table,
                Dict("ConditionExpression" => "attribute_not_exists(run_id)");
                aws_config=ctx.aws)
            push!(created, pkg)
        catch err
            is_conditional_failure(err) || rethrow()   # a concurrent expansion won this item
        end
    end
    isempty(created) && return 0, requeue

    # existing dep items must learn about their new dependents, or completion
    # would never decrement them
    for (dep, pkgs) in dependents
        haskey(existing, dep) || continue
        news = [p for p in pkgs if p in Set(created)]
        isempty(news) && continue
        try
            Dynamodb.update_item(
                ddb_item(Dict("run_id" => seal_run_id, "job_key" => job_key(SEAL_CONFIG_NAME, dep))),
                ctx.cfg.jobs_table,
                Dict("UpdateExpression" => "SET dependents = list_append(if_not_exists(dependents, :empty), :new)",
                     "ExpressionAttributeValues" => ddb_item(Dict(
                         ":empty" => Any[], ":new" => news)));
                aws_config=ctx.aws)
        catch err
            @warn "failed to extend dependents; reconciliation will heal" dep err
        end
    end

    # reactivate + grow the shared run atomically with respect to the count
    Dynamodb.update_item(ddb_item(Dict("run_id" => seal_run_id)), ctx.cfg.runs_table,
        Dict("UpdateExpression" => "SET #s = :active REMOVE finished_at ADD total_jobs :n",
             "ExpressionAttributeNames" => Dict("#s" => "status"),
             "ExpressionAttributeValues" => ddb_item(Dict(
                 ":active" => "active", ":n" => length(created))));
        aws_config=ctx.aws)

    ready = [p for p in created if remaining_of[p] == 0]
    return length(created), [ready; requeue]
end

"Enqueue seal jobs on the seal queue."
enqueue_seal_jobs(ctx::FarmCtx, seal_run_id::AbstractString, packages) =
    enqueue_jobs(ctx, [JobRef(seal_run_id, SEAL_CONFIG_NAME, pkg) for pkg in packages];
                 queue_url=ctx.cfg.seal_queue_url)

"""
Decrement each dependent's readiness counter after a seal job reached a
terminal state, enqueueing those that hit zero. *Any* terminal state counts:
an unsealable dep must not orphan its dependents — their own seal jobs then
discover the failure first-hand, cheaply and definitively.
"""
function propagate_seal_completion(ctx::FarmCtx, seal_run_id::AbstractString,
                                   dependents::Vector{String})
    ready = String[]
    ready_lock = ReentrantLock()
    asyncmap(dependents; ntasks=16) do dep
        try
            resp = Dynamodb.update_item(
                ddb_item(Dict("run_id" => seal_run_id, "job_key" => job_key(SEAL_CONFIG_NAME, dep))),
                ctx.cfg.jobs_table,
                Dict("ConditionExpression" => "remaining >= :one",
                     "UpdateExpression" => "ADD remaining :neg",
                     "ExpressionAttributeValues" => ddb_item(Dict(":one" => 1, ":neg" => -1)),
                     "ReturnValues" => "ALL_NEW");
                aws_config=ctx.aws)
            attrs = ddb_parse(resp["Attributes"])
            if attrs["remaining"] == 0 && get(attrs, "status", "") == "pending"
                lock(() -> push!(ready, dep), ready_lock)
            end
        catch err
            is_conditional_failure(err) || @warn "failed to decrement seal dependent" dep err
        end
        nothing
    end
    isempty(ready) || enqueue_seal_jobs(ctx, seal_run_id, ready)
    return ready
end

"""
Heal a seal run's readiness bookkeeping: any pending job whose deps are all
terminal but whose counter is stuck (worker died mid-decrement, message died
to the DLQ) is zeroed and enqueued. Called — throttled — by workers whose
fill-poll found the seal queue empty while a test job is still gated, i.e. by
exactly the party that cares.
"""
function reconcile_seal_run(ctx::FarmCtx, seal_run_id::AbstractString)
    jobs = run_jobs(ctx, seal_run_id)
    status = Dict(String(j["package"]) => String(get(j, "status", "pending")) for j in jobs)
    healed = String[]
    for job in jobs
        get(job, "status", "") == "pending" || continue
        pkg = String(job["package"])
        if get(job, "remaining", 0) <= 0
            # Ready but apparently unclaimed: its message may have been lost
            # (expansion died pre-send, retention expired) — or it is merely
            # deep in a congested queue, which is why re-sends back off
            # exponentially on a CAS-elected enqueued_at lease instead of
            # firing every pass (unconditional per-pass re-sends amplified the
            # very backlog that delayed the claims, seen live at 2× scale-up).
            # The stamp only exists once a reconcile pass touched the job:
            # normal expansion/decrement sends stay stamp-free and cheap.
            rearms = Int(get(job, "rearms", 0))
            seen = String(get(job, "enqueued_at", ""))
            cutoff = isodate(Dates.now(Dates.UTC) - REARM_PENDING_AFTER * 2^min(rearms, 5))
            (isempty(seen) || seen < cutoff) || continue
            won = try
                Dynamodb.update_item(
                    ddb_item(Dict("run_id" => seal_run_id, "job_key" => job_key(SEAL_CONFIG_NAME, pkg))),
                    ctx.cfg.jobs_table,
                    Dict("ConditionExpression" => "#s = :pending AND " *
                             (isempty(seen) ? "attribute_not_exists(enqueued_at)" : "enqueued_at = :seen"),
                         "UpdateExpression" => "SET enqueued_at = :now ADD rearms :one",
                         "ExpressionAttributeNames" => Dict("#s" => "status"),
                         "ExpressionAttributeValues" => ddb_item(Dict(
                             ":pending" => "pending", ":now" => isodate(), ":one" => 1,
                             (isempty(seen) ? () : ((":seen" => seen),))...)));
                    aws_config=ctx.aws)
                true
            catch err
                is_conditional_failure(err) || rethrow()
                false
            end
            won && push!(healed, pkg)
            continue
        end
        deps = String.(get(job, "deps", String[]))
        all(d -> seal_terminal(get(status, d, "sealed")), deps) || continue
        try
            Dynamodb.update_item(
                ddb_item(Dict("run_id" => seal_run_id, "job_key" => job_key(SEAL_CONFIG_NAME, pkg))),
                ctx.cfg.jobs_table,
                Dict("ConditionExpression" => "#s = :pending",
                     "UpdateExpression" => "SET remaining = :zero",
                     "ExpressionAttributeNames" => Dict("#s" => "status"),
                     "ExpressionAttributeValues" => ddb_item(Dict(
                         ":pending" => "pending", ":zero" => 0)));
                aws_config=ctx.aws)
            push!(healed, pkg)
        catch err
            is_conditional_failure(err) || @warn "seal reconciliation update failed" pkg err
        end
    end
    # cycle amnesty: a pending component whose only non-terminal deps are its
    # own members can never decrement itself free — the counters deadlock.
    # seal_dep_graph now collapses cycles at creation, but items from before
    # that (and any rebuilt by races) still carry them; release such
    # components whole, exactly as the collapse would have: members seal with
    # their cyclic deps cold. Running deps are external liveness (their
    # completion decrements normally), so components pointing at one wait.
    pending_deps = Dict{String,Vector{String}}()
    for job in jobs
        get(job, "status", "") == "pending" || continue
        pkg = String(job["package"])
        pending_deps[pkg] = [String(d) for d in get(job, "deps", String[])
                             if !seal_terminal(get(status, String(d), "sealed"))]
    end
    comp = scc_ids(pending_deps)
    blocked_externally = Set{Int}()
    for (pkg, deps) in pending_deps, d in deps
        get(comp, d, 0) == comp[pkg] || push!(blocked_externally, comp[pkg])
    end
    members = Dict{Int,Vector{String}}()
    for pkg in keys(pending_deps)
        push!(get!(Vector{String}, members, comp[pkg]), pkg)
    end
    for (cid, pkgs) in members
        cid in blocked_externally && continue
        length(pkgs) >= 2 || continue   # free singletons belong to the branch above
        released = String[]
        for pkg in pkgs
            try
                Dynamodb.update_item(
                    ddb_item(Dict("run_id" => seal_run_id, "job_key" => job_key(SEAL_CONFIG_NAME, pkg))),
                    ctx.cfg.jobs_table,
                    Dict("ConditionExpression" => "#s = :pending",
                         "UpdateExpression" => "SET remaining = :zero",
                         "ExpressionAttributeNames" => Dict("#s" => "status"),
                         "ExpressionAttributeValues" => ddb_item(Dict(
                             ":pending" => "pending", ":zero" => 0)));
                    aws_config=ctx.aws)
                push!(released, pkg)
            catch err
                is_conditional_failure(err) || @warn "cycle release failed" pkg err
            end
        end
        append!(healed, released)
        isempty(released) ||
            @info "released deadlocked seal cycle" seal_run_id n=length(released) sample=first(sort(released), min(length(released), 5))
    end
    isempty(healed) || enqueue_seal_jobs(ctx, seal_run_id, healed)
    isempty(healed) || @info "reconciled stuck seal jobs" seal_run_id n=length(healed)
    return healed
end


"PkgEval fork support for `goal = :seal` evaluations (see the farm branch of
KenoAIStaging/PkgEval.jl); without it workers neither poll the seal queue nor
gate test jobs — the pre-sealing farm, exactly."
pkgeval_supports_seal() = isdefined(PkgEval, :evaluate_seal)

# tests (and exotic deployments) can point the graph at a fixture registry
# instead of PkgEval's checkout
const SEAL_REGISTRY_OVERRIDE = Ref{Union{Nothing,String}}(nothing)

seal_registry_dir(config::PkgEval.Configuration) =
    @something(SEAL_REGISTRY_OVERRIDE[], PkgEval.get_registry(config))

"""
    setup_sealing(ctx, run, fresh) -> Union{Nothing,Dict{config_name,seal_run_id}}

Expansion-side sealing setup: per config, ensure the shared seal run, add seal
jobs for this run's fresh packages (with dependency counters from the static
graph) and enqueue the ready ones.

The decision is symmetric across configs — all seal or none do (`nothing`) —
because a run whose sides evaluate under different schemes isn't comparing
julias anymore: timing, precompile behavior and protocol-induced failures all
masquerade as one-sided regressions (#12, 31 spurious kill→ok flips). And it
is *definitive*: the hook probe answers only when the sandboxed julia
actually ran (an unprobeable config — unstaged build, sandbox failure —
throws out of expansion, whose redelivery retries once the cause clears;
"couldn't ask" must never freeze into "unsupported"). Setup failures after
detection degrade the whole run to cold, never one config.
"""
function setup_sealing(ctx::FarmCtx, run::AbstractDict, fresh::Vector{JobRef})
    sealing_enabled(ctx.cfg) || return nothing
    wanted = Tuple{Any,String,Vector{String}}[]
    for config_dict in run["configs"]
        name = String(config_dict["name"])
        packages = sort!(unique([j.package for j in fresh if j.config == name]))
        isempty(packages) || push!(wanted, (config_dict, name, packages))
    end
    isempty(wanted) && return nothing
    # phase 1: a definitive hook verdict for every config before any setup
    for (config_dict, name, _) in wanted
        fingerprint = seal_fingerprint(config_dict)
        if !detect_seal_support(config_from_dict(config_dict), fingerprint)
            @info "julia lacks the cache-fetch hook; whole run evaluates cold (scheme symmetry)" config=name
            return nothing
        end
    end
    learned = try
        learned_edges(ctx)
    catch err
        @warn "failed to load learned edges; using the registry graph alone" err
        Dict{String,Vector{String}}()
    end
    # phase 2: per-config setup, all or nothing — a partial seal_runs map
    # would evaluate the configs under different schemes. Orphaned seal runs
    # from an abandoned partial setup are harmless: they are shared by
    # fingerprint and still warm the store.
    mapping = Dict{String,String}()
    for (config_dict, name, packages) in wanted
        try
            fingerprint = seal_fingerprint(config_dict)
            config = config_from_dict(config_dict)
            id = ensure_seal_run(ctx, config_dict, fingerprint)
            registry = seal_registry_dir(config)
            graph = seal_dep_graph(registry, packages, learned)
            ncreated, ready = add_seal_jobs(ctx, id, packages, graph)
            isempty(ready) || enqueue_seal_jobs(ctx, id, ready)
            mapping[name] = id
            @info "sealing set up" run_id=run["run_id"] config=name seal_run=id ncreated nready=length(ready)
        catch err
            @error "sealing setup failed; whole run evaluates cold (scheme symmetry)" name exception=(err, catch_backtrace())
            return nothing
        end
    end
    return isempty(mapping) ? nothing : mapping
end

# reconciliation is cheap but not free (a full seal-run query); one worker
# retrying every few minutes while gated is plenty
const RECONCILE_AT = Dict{String,Float64}()
const RECONCILE_LOCK = ReentrantLock()

function maybe_reconcile_seal_run(ctx::FarmCtx, seal_run_id::AbstractString; every::Real=300)
    due = lock(RECONCILE_LOCK) do
        if time() - get(RECONCILE_AT, seal_run_id, 0.0) >= every
            RECONCILE_AT[seal_run_id] = time()
            true
        else
            false
        end
    end
    due || return nothing
    try
        reconcile_seal_run(ctx, seal_run_id)
    catch err
        @warn "seal reconciliation failed" seal_run_id err
    end
    return nothing
end


## the test-job gate

"""
    seal_state(ctx, run, job) -> (:none | :pending | :terminal, seal_run_id)

Whether (and where) `job`'s package is being sealed. `:none` — sealing is off
for this run/config or the seal job does not exist; the test proceeds
immediately, exactly like the pre-sealing farm.
"""
function seal_state(ctx::FarmCtx, run::AbstractDict, job::JobRef)
    seal_runs = get(run, "seal_runs", nothing)
    seal_runs isa AbstractDict || return (:none, "")
    id = get(seal_runs, job.config, nothing)
    id isa AbstractString || return (:none, "")
    return (seal_status(ctx, String(id), job.package), String(id))
end

"Status of one seal job: `:none` (no such job — proceed), `:pending`, or `:terminal`."
function seal_status(ctx::FarmCtx, seal_run_id::AbstractString, package::AbstractString)
    resp = aws_retry() do
        Dynamodb.get_item(
            ddb_item(Dict("run_id" => seal_run_id,
                          "job_key" => job_key(SEAL_CONFIG_NAME, package))),
            ctx.cfg.jobs_table; aws_config=ctx.aws)
    end
    haskey(resp, "Item") || return :none
    item = ddb_parse(resp["Item"])
    return seal_terminal(String(get(item, "status", "pending"))) ? :terminal : :pending
end

"The seal job's own item (deps for materialization, dependents for propagation)."
function get_seal_item(ctx::FarmCtx, job::JobRef)
    resp = aws_retry() do
        Dynamodb.get_item(
            ddb_item(Dict("run_id" => job.run_id, "job_key" => job_key(job))),
            ctx.cfg.jobs_table; aws_config=ctx.aws)
    end
    haskey(resp, "Item") ? ddb_parse(resp["Item"]) : nothing
end
