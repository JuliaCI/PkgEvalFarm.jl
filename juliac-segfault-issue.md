# Draft upstream issue: juliac --trim binary segfaults on non-main thread under Lambda (parallel GC mark suspect)

**Environment:** juliac-compiled binary (`--experimental --trim=safe`, `JULIA_CPU_TARGET=sandybridge`),
Julia 1.13.0-rc1, running on AWS Lambda `provided.al2023` (firecracker, 1024 MB cgroup,
~0.57 vCPU, 2 vCPUs visible), x86_64.

**Symptom:** deterministic-in-production segfault while lazily parsing a ~7.7 MB / 24k-item
JSON payload (JSON.jl lazy API, ~1.3 M allocations for the full parse):

```
[2] signal 11 (1): Segmentation fault
in expression starting at none:0
Allocations: 1318316 (Pool: 1318267; Big: 49); GC: 2
```

- `[2]`: the faulting thread is not the main thread — no Julia backtrace is printed
  (crash handler only unwinds the faulting thread). Binary runs with default thread
  settings; 2 vCPUs visible ⇒ GC helper thread(s) exist.
- Reproduced on every invocation that runs this parse (hourly, 7+ consecutive), always
  at the same allocation ballpark, always after `GC: 2`.
- Before the segfault era, the same workload showed two 300 s hangs (Lambda timeout,
  88 MB used) — possibly the same defect manifesting as a wedge instead of a crash.

**Not reproducible outside Lambda** (same juliac invocation, same code path
byte-for-byte, same captured payloads), under any of:
- default settings (huge host heap; 5 consecutive full parses)
- `JULIA_HEAP_SIZE_HINT=150M` (forcing collections during the parse)
- `taskset -c 0,1` + small heap, 10 repeated runs

Remaining environmental deltas: AL2023 glibc vs Debian, firecracker, true 1024 MB cgroup
memory accounting, sub-vCPU throttling (long involuntary pauses mid-GC), Lambda
freeze/thaw between invocations.

**Discriminating experiment in flight:** `JULIA_NUM_GC_THREADS=0` on the production
function. If crashes stop, parallel marking in the trimmed image is implicated
(missing rooting/metadata visible only to concurrent mark threads?).

Also observed independently (likely separate issue): `Base.lpad` and
`DateTime(::String, ::DateFormat)` fail `--trim=safe` verification, and a minimal
entrypoint including the same module set trips 8 Parsers.jl float-path verifier errors
that the production entrypoint (with `juliac-trim-compat.jl` overrides) does not.

Reproducer harness (parse driver + captured payloads) available on request.
