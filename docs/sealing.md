# Sealed compilecache

Design for sharing precompilation work across the fleet — and, eventually, for
producing the artifacts a package server could serve. All coordination lives
in farm code plus a ~25-line loader hook (`Base.CACHE_FETCH_HOOK`) in the
Julia under test; julias without the hook simply run unsealed.

## Overview

A **seal job** for package X performs everything `Pkg.test(X)` does up to the
point of running tests: install X, resolve its test environment (via TestEnv,
exactly like PkgEval's existing precompile phase), and precompile it with the
exact CLI flags the test process will use (`--check-bounds=yes` + the config's
`julia_args` — flag mismatch would silently make every artifact unreusable,
see the `JULIA_PKG_PRECOMPILE_AUTO=0` note in PkgEval's sandbox setup). The
produced compilecache pair is published to S3, immutably. A **test job** for
X waits (bounded) for seal(X) to reach a terminal state and then runs with
its sandbox pointed at the worker's loopback cache proxy — fully warm,
through the loader hook, with stock validation semantics on every fetched
candidate.

Seal and derivation jobs are the *only* writers to the shared S3 layer. Test
jobs keep using the machine-local scavenged cache exactly as before; that
cache never crosses machines. This confines the poisoning surface of the
cross-machine layer to what precompilation itself does — the same code any
user executes on `Pkg.add`, which is the right trust bar for ever serving
these files.

## S3 layout

Everything lives in the results bucket under a *seal id* — a fingerprint of
the configuration fields that affect compilecache validity (julia spec,
buildflags, julia_args, registry; scheduling-only fields like time limits and
cpu pinning are excluded so they don't fragment the cache):

    compilecache/<seal-id>/kv/<uuid>/<key>         # framed .ji+.so pair
    compilecache/<seal-id>/kv/<uuid>/<key>.meta    # names + direct-dep identities

`<key>` is the sha256 of the artifact's full build-context preimage (see the
protocol below). Objects are written create-only (`If-None-Match: *`):
**first writer wins, objects are immutable**. Losing a publication race is
detected by comparing the sha256 checksum of the existing object (uploads
carry `x-amz-checksum-sha256`).

Precompile determinism is not assumed anywhere: resolution is a pure function
of (registry snapshot, source, julia build), so seal(X) reproduces the same
environment computation test(X) will perform; keys bind the full build
context, so an inexact reproduction produces a different key, never a wrong
hit; and Julia's loader validates every fetched candidate itself, so a stale
or mismatched artifact degrades to a local compile, never to a wrong result.

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
platform-conditional deps) is handled by the want/derivation machinery below;
seal-job discovery is handled by construction (the seal job resolves the real
test env and reports its manifest, which is where learned edges come from).

## Worker slot policy: prefer sealing, hold-and-fill

Sealing gets its own SQS queue: priority between queues is the only ordering
SQS honors. A slot's claim order is seal → slow → fast. When a claimed *test*
job's seal(X) is still pending, the slot **holds the claim** (heartbeats
continue; nothing is re-enqueued, so no receive-count or attempt accounting is
disturbed) and fills the wait with seal jobs: poll the seal queue, run what it
gets, recheck seal(X) between jobs. Deadline or seal(X) terminal → run the
test. "Cold" is soft: the proxy still serves whatever was sealed by then, so
an aggressive deadline is safe.

Waiting slots polling the seal queue is what makes this deadlock-free: every
pending seal is either in flight on some slot or gated on deps whose jobs are
queued where a waiting slot's poll can reach them. The residual liveness holes
(a seal message dying to the DLQ without its dependents being decremented, a
worker crashing mid-decrement) are healed by `reconcile_seal_run`, run — 
throttled — by exactly the party that cares: a slot whose fill-poll came up
empty while its test job is still gated.

## Consumption: the worker's loopback proxy

The worker runs a loopback HTTP proxy per process; sandboxes reach it via
`PKGEVAL_CACHE_SERVER`. The proxy answers from a local disk cache
(`PKGEVAL_SEAL_CACHE`, immutable objects trusted forever), then S3. There is
no filesystem-level cache layer and no daemon in the sandbox.

## Why demand is a protocol, not a filesystem

An earlier revision of this design had file-shaped delivery: a policy FUSE
that could *block* a cache-dir miss while an in-flight seal finished, later a
read-only pre-materialized depot mount. Both were dropped for fundamental
reasons. A path-shaped miss carries no resolution context (version, dep
build_ids, preferences), so nothing behind a filesystem interface can cause
the *right* artifact to be produced — it can only serve already-published
bytes, and blocking on `seal(D)` is merely a bet that D's own resolution
coincides with the requester's. And a cachefile materialized into a
`packages/`-less secondary depot fails the loader's `@depot` source-path
staleness check outright, so it is silently recompiled — file delivery must
land in the *primary* depot, next to the sources it references, which is
exactly where the loader hook writes. Demand-driven artifact generation
inherently needs the resolver's view — the hook has it; a filesystem does
not. The dynamic tail (runtime `Pkg.add` and friends) still compiles locally
when its keys were never published, and learned edges fold it into the
static closure over successive runs.

## The cache protocol

A file-delivery scheme where seal(X) publishes its whole closure has a trust
hole: the closure contains dependency files produced while X's code ran, so
a malicious or buggy X could poison artifacts other packages load. The
protocol closes it by moving demand to a loader hook with full resolution
context and making publication per-unit under registry authority:

- The julia-under-test carries `Base.CACHE_FETCH_HOOK` (the
  `cache-fetch-hook` branch); PkgEval's `scripts/cache_client.jl` installs a
  client in the driver processes when `PKGEVAL_CACHE_SERVER` is set. On a
  compilecache miss it computes the full build context — julia build, uuid,
  version, tree hash, cache flags, prefs, and per direct dep its build_id,
  version and own context key — and POSTs the whole preimage to the
  worker's loopback proxy (`/ensure`): one request that serves the
  artifact, or creates its derivation and holds until it terminates. Asks
  are inherently bottom-up (a preimage needs its deps' build_ids, which
  exist only once the deps materialized), which the loader's walk provides.
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
want into a derivation job on the seal queue; an executor slot walks the
closure by key through the meta chain, pins the *entire* environment
(`/derive_pins.toml`), and runs `goal = :derive` — like `:seal` but without
TestEnv, since the requester wanted the package as a dependency; the
artifacts themselves arrive in-sandbox through the probe-only fetch below. The produced
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
bottom-up walk, so whole chains resolve within one pass. Holds have deliberately no timeout: releasing early would make the
requester compile a private copy of what the rest of its job expects to
share, silently breaking key convergence — failure is owned at the job
level (evaluation time limits, heartbeat bounds), and a terminally-failed
derivation releases every holder as a 404, at which point a local compile
is correct rather than a compromise. Dead derivation items are re-armed by
a fresh identical want rather than acting as tombstones.

### Extensions (v3 preimages)

Package extensions have no registry identity of their own, so the v2 line
format cannot express them; they were the dominant residual-miss class
(~5%, plus the `unsealable` cascade through dependents). A v3 preimage —
v2 plus an `ext_of=<parent uuid>` line — keys an extension by derivation:
its uuid must equal `uuid5(ext_of, name)` (checked at parse), its
version/tree are the parent's (the extension source lives in the parent's
tree), and its dep lines carry the parent and the trigger packages, all
loaded before the extension so their build_ids are known. Package
preimages stay v2: no published key changes. Publication authority is
structural — the worker computes `uuid5(parent, name)` itself and requires
the parent to be a registry package; seal jobs publish their unit's
triggered extensions alongside the unit under that derived authority.
Extension derivations install the want's deps directly (`Pkg.add` can't
name an extension; it compiles once parent and triggers land), including
uuid-only entries for unversioned stdlib triggers. Old proxies reject v3
as malformed, which clients already treat as an ordinary miss.

Derivation sandboxes fetch in **probe-only** mode (`PKGEVAL_CACHE_NOHOLD=1`,
an `X-Nohold` header on every ensure): published deps are consumed from the
store — essential, because the produced preimage then carries exactly the
canonical dep build_ids consumers compute, making the derivation's key the
key consumers want — but a miss answers 404 immediately, never holds, and
never enqueues. Holding on an unpublished key would deadlock the derivation
against the very publication it (or a donor sibling) is supposed to perform.
The probe bypasses the proxy's negative cache (a sibling may have published
within its TTL). Deps that genuinely aren't published yet get compiled
locally; that derivation's key is then inexact, and a later pass's fresh
want re-derives against the published set — convergence is monotone.

There is no global switch. Expansion decides per configuration whether
sealing happens at all — the julia under test must carry
`Base.CACHE_FETCH_HOOK`, detected by running it *sandboxed* (never on the
host: detection carries exactly the same trust as evaluation); hookless
julias run unsealed, exactly the pre-sealing behavior, and detection
failures fall back the same way. The seal run item records its scheme
(`"protocol"`) create-only per fingerprint; gates treat any other value
(runs created by retired schemes) as gating nothing, so a mixed-deploy
window degrades to cold evaluation, never to a mixed state.

## Degradation ladder

Every layer is an accelerator; removing any of them reproduces today's farm:
no seal queue configured → no sealing, workers unchanged; PkgEval too old for
`goal = :seal` → workers skip the seal queue and never gate tests; S3
unreachable mid-job → Julia compiles locally; dynamic discoveries → compile
locally. The only hard dependency added to the *test* path is one `GetItem`
per job plus a bounded wait.
