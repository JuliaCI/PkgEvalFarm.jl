# Sealed compilecache

Design for sharing precompilation work across the fleet — and, eventually, for
producing the artifacts a package server could serve. The consumer side is
deliberately dumb (files in depots, stock loading semantics); all coordination
lives in farm code, because the farm evaluates *arbitrary* Julia builds and can
never require protocol support inside the Julia under test.

## Overview

A **seal job** for package X performs everything `Pkg.test(X)` does up to the
point of running tests: install X, resolve its test environment (via TestEnv,
exactly like PkgEval's existing precompile phase), and precompile it with the
exact CLI flags the test process will use (`--check-bounds=yes` + the config's
`julia_args` — flag mismatch would silently make every artifact unreusable,
see the `JULIA_PKG_PRECOMPILE_AUTO=0` note in PkgEval's sandbox setup). The
produced compilecache files are published to S3, immutably. A **test job** for
X waits (bounded) for seal(X) to reach a terminal state and then runs with the
sealed artifacts mounted as a read-only secondary depot — fully warm, through
completely stock loader semantics.

Seal jobs are the *only* writers to the shared S3 layer. Test jobs keep using
the machine-local scavenged cache exactly as before; that cache never crosses
machines. This confines the poisoning surface of the cross-machine layer to
what precompilation itself does — the same code any user executes on
`Pkg.add`, which is the right trust bar for ever serving these files.

## S3 layout

Everything lives in the results bucket under a *seal id* — a fingerprint of
the configuration fields that affect compilecache validity (julia spec,
buildflags, julia_args, registry; scheduling-only fields like time limits and
cpu pinning are excluded so they don't fragment the cache):

    compilecache/<seal-id>/files/v1.13/<Package>/<slug>.{ji,so}   # depot-shaped
    compilecache/<seal-id>/index/<Package>.json                   # closure index

Both are written create-only (`If-None-Match: *`): **first writer wins, objects
are immutable**. Losing a publication race is detected by comparing the sha256
checksum of the existing object (uploads carry `x-amz-checksum-sha256`); a
mismatch means some already-published dependent references a file we failed to
publish — the affected subtree is simply not published by this job (each
package has its own seal job, so nothing is lost, only deferred).

The `files/` layout mirrors a depot, so a future package server can front the
bucket directly and a resolving client can compute the exact paths it wants.
The closure index lists the *transitive* file set for one package, so a
consumer fetches one small object and then knows every file to download.

Precompile determinism is not assumed anywhere: resolution is a pure function
of (registry snapshot, source, julia build), so seal(X) reproduces the same
environment computation test(X) will perform; and Julia's loader validates
every cache candidate itself, so a stale or mismatched artifact degrades to a
local compile, never to a wrong result.

By default seal jobs produce what PkgEval test jobs produce today (`.ji` under
`--pkgimages=existing`), keeping test behavior byte-identical to the unsealed
farm. Generating native pkgimages (the package-server payload) is a deliberate
future flip of the seal config's flags, not a code change.

## Scheduling: static graph + counters, dynamic discovery as the miss path

Expansion builds a *static* dependency graph from the registry (union of
Deps.toml sections — an over-approximation) merged with **learned edges**
(observed in previous runs' resolved manifests, stored under the `_learned-edges`
partition of the jobs table). The graph is a memo table, not a promise:
correctness never depends on it. It exists to make races rare and duplicate
cold compiles unlikely.

Each seal job item stores its in-run `deps`, reverse `dependents`, and a
`remaining` counter. Expansion enqueues only jobs with `remaining == 0`; a
completing seal job atomically decrements each dependent's counter and
enqueues those that reach zero. Any terminal state (sealed, unsealable, error)
decrements — a dep that failed to precompile does not orphan its dependents,
whose own seal jobs then discover the failure first-hand and cheaply.

Seal jobs hang off a **seal run** (`run_id = "seal-<seal-id-prefix>"`,
config name `"seal"` — reserved) so counters, completion, DLQ handling and
reconciliation all reuse the existing run machinery. Seal runs are shared
across user runs with the same seal id: a recurring baseline config gets
cross-run cache reuse for free, and later runs only add jobs for packages not
yet covered (create-only item writes keep the totals honest).

Test-job dependency discovery that the static graph missed (runtime `Pkg.add`,
platform-conditional deps) is handled by the policy filesystem below; seal-job
discovery is handled by construction (the seal job resolves the real test env
and reports its manifest, which is where learned edges come from).

## Worker slot policy: prefer sealing, hold-and-fill

Sealing gets its own SQS queue: priority between queues is the only ordering
SQS honors. A slot's claim order is seal → slow → fast. When a claimed *test*
job's seal(X) is still pending, the slot **holds the claim** (heartbeats
continue; nothing is re-enqueued, so no receive-count or attempt accounting is
disturbed) and fills the wait with seal jobs: poll the seal queue, run what it
gets, recheck seal(X) between jobs. Deadline or seal(X) terminal → run the
test. "Cold" is soft: the materialized depot still serves whatever was sealed
by then, so an aggressive deadline is safe.

Waiting slots polling the seal queue is what makes this deadlock-free: every
pending seal is either in flight on some slot or gated on deps whose jobs are
queued where a waiting slot's poll can reach them. The residual liveness holes
(a seal message dying to the DLQ without its dependents being decremented, a
worker crashing mid-decrement) are healed by `reconcile_seal_run`, run — 
throttled — by exactly the party that cares: a slot whose fill-poll came up
empty while its test job is still gated.

## Consumption: depot stacking, one materialized layer

    JULIA_DEPOT_PATH = ~/.julia (job, rw) : materialized sealed dir (ro)

The worker keeps a local cache of downloaded artifacts (`PKGEVAL_SEAL_CACHE`)
and, before each job, hardlinks the job's closure into a plain per-job
directory, bind-mounted read-only. Native filesystem, no daemon anywhere.

- A **test** job materializes from `index(X)`: the exact transitive file list
  `seal(X)` resolved, which is exactly what `test(X)` will resolve.
- A **seal** job materializes its deps from prefix *listings* (`all_versions`),
  not indexes: X's compat may resolve a dep to a different version than the
  dep's own seal job sealed, and any published variant is canonical — this is
  what makes pull-before-compile effective under version skew. Whatever X
  cold-compiles anyway (unpublished versions included) gets published and
  indexed by X, so its test job is still exactly warm.

## Why there is no on-demand (filesystem-level) layer

An earlier revision of this design had a policy FUSE at the end of the depot
path that could *block* a cache-dir miss while an in-flight seal finished —
suspension as filesystem latency. It was dropped for a fundamental reason: a
path-shaped miss carries no resolution context (version, dep build_ids,
preferences), so nothing behind a filesystem interface can cause the *right*
artifact to be produced — it can only serve already-published bytes, and
blocking on `seal(D)` is merely a bet that D's own resolution coincides with
the requester's. Demand-driven artifact generation inherently needs the
resolver's view; that is the future Pkg client protocol, not a farm concern.
The dynamic tail (runtime `Pkg.add` and friends) therefore compiles locally,
exactly as today, and learned edges fold it into the static closure over
successive runs. The job-level gate is unaffected: it is package-scoped with
full context via the `test(X)` ↔ `seal(X)` mapping.

## The cache-protocol scheme (auto-selected per julia build)

The depot scheme above has a residual trust hole: seal(X)'s published closure
contains dependency files produced while X's code ran, so a malicious or
buggy X can poison artifacts other packages load. The protocol scheme closes
it by moving demand to a loader hook with full resolution context:

- The julia-under-test carries `Base.CACHE_FETCH_HOOK` (the
  `cache-fetch-hook` branch); PkgEval's `scripts/cache_client.jl` installs a
  client in the driver processes when `PKGEVAL_CACHE_SERVER` is set. On a
  compilecache miss it computes a key over the *entire* build context —
  julia build, uuid, version, tree hash, cache flags, prefs, and the exact
  `(dep_uuid, build_id)` pairs — GETs a loopback proxy the worker runs, and
  reports misses (`/want`) with the full context, the forward hook for
  derivation scheduling.
- Publication is worker-side and namespaced: only the sealed unit's own
  cachefile pair, only under the uuid the *registry* (never the sandbox)
  resolves for it. A malicious seal job can poison nothing but its own
  package — which its consumers had already decided to run.
- Objects are immutable framed `.ji`+pkgimage pairs under
  `compilecache/<seal-id>/kv/<uuid>/<key>`; the loader still revalidates
  every fetched candidate, so a wrong object is a wasted GET, never a wrong
  load.

**Stage 2 — derivations.** A v2 want is a complete work order: per direct dep
it carries the resolved version and the dep's *own* context key, and every
published artifact carries a `.meta` sidecar (filenames plus its direct deps'
identities and keys), making the store a by-key DAG. The proxy dedups each
want into a derivation job on the seal queue; an executor slot resolves the
closure by key through the meta chain (declining if anything was never
published), materializes it, pins the *entire* environment
(`/derive_pins.toml`), and runs `goal = :derive` — like `:seal` but without
TestEnv, since the requester wanted the package as a dependency. The produced
key is checked against the want; on mismatch (inexact environment
reproduction) the artifact still publishes under its true key — which is
exactly the canonical-chain key later bottom-up consumers compute, so keys
converge across passes. Trust is unchanged: executing a derivation for D
runs only code from D's closure, and publication still goes under the
registry's uuid for D.

Ordering among derivations is dataflow by blocking: a GET whose exact key
has a derivation in flight is *held* by the proxy until the artifact lands
(the suspended sandbox idles at zero CPU; PkgEval's inactivity windows are
widened for seal/derive goals to accommodate this), and the worker donates
the held slot's capacity to seal-queue work — typically the very derivation
being waited on. Wants are posted dep-before-dependent by the loader's
bottom-up walk, so whole chains resolve within one pass. Holds are bounded
(`PKGEVAL_PROXY_HOLD`, default 240 s — inside a test job's inactivity
window) and time out to a local compile: liveness always wins. Dead
derivation items are re-armed by a fresh identical want rather than acting
as tombstones.

There is no global switch. Expansion decides the scheme per configuration —
"protocol" iff the julia under test carries `Base.CACHE_FETCH_HOOK`, detected
by running it *sandboxed* (never on the host: detection carries exactly the
same trust as evaluation) — and records it on the (per-fingerprint,
create-only) seal run item. Every job of a seal run, and every test job
gating on it, therefore sees one scheme; hookless julias get the depot
scheme, i.e. exactly the pre-protocol behavior, and detection failures fall
back the same way. Suboptimal beats a mixed state.

## Degradation ladder

Every layer is an accelerator; removing any of them reproduces today's farm:
no seal queue configured → no sealing, workers unchanged; PkgEval too old for
`goal = :seal` → workers skip the seal queue and never gate tests; S3
unreachable mid-job → Julia compiles locally; dynamic discoveries → compile
locally. The only hard dependency added to the *test* path is one `GetItem`
per job plus a bounded wait.
