# juliac --trim: image-resident FileWatching.FDWatchers loses its old→young edge; GC frees the live backing Memory (use-after-free)

**Environment:** juliac binary (`--experimental --trim=safe`, `JULIA_CPU_TARGET=sandybridge`),
Julia 1.13.0-rc1, x86_64-linux. First observed as a deterministic production segfault on
AWS Lambda `provided.al2023`; later reproduced locally with the same binary in ~20 s.

## Root cause (established via rr reverse execution)

`FileWatching.FDWatchers::Vector{Union{Nothing,_FDWatcher}}` is serialized into the
juliac image. At runtime, `Downloads.Curl.socket_callback → FDWatcher → _FDWatcher`
grows it (`resize!`), storing a **freshly allocated Memory into the old, image-resident
Vector**. In the trimmed image that old→young edge is not honored — write barrier
elided, or image objects not correctly part of the remembered-set machinery — so a
subsequent GC sweeps the still-referenced Memory, whose pool page is promptly recycled.

rr timeline for the corrupted element slot (reverse from the crash):

1. Crash: `_FDWatcher` (FileWatching.jl:349) loads `FDWatchers.data[fd]`, gets `0xa0`
   (recycled bytes; the code then faults reading `-0x8(elem)` — the type tag — at
   address 0x98). Backtrace: `_FDWatcher ← FDWatcher ← socket_callback
   (Downloads/Curl/Multi.jl:183) ← curl mev_sh_entry_update / mev_assess /
   multi_run_dirty ← curl_multi_socket_action ← do_multi ← timer_callback closure`.
2. Watchpoint + reverse-continue: the slot's bytes were last written by
   **`ijl_alloc_string(len=21)` → `jl_gc_alloc_` → `jl_set_typeof`** stamping a *new
   string object* (from an unrelated `joinpath`) into the reused page — i.e. the
   Vector's backing Memory had been freed by GC and its page reallocated.
3. The Vector object itself (image data segment address) survives with a stale `ref`;
   only the runtime-allocated Memory was collected.

Two crash flavors of the same defect, both captured:

- **Mutator flavor** (local, above): post-GC read of the recycled memory
  (`SEGV_MAPERR`, addr 0x98).
- **Marker flavor** (production Lambda, every affected invocation): GC crashes *during*
  collection in `gc_try_claim_and_push` (`mov 0x100(%r12)` with garbage base 0x640,
  fault address 0x740) — the marker following the dangling edge itself.

## Reproduction

- Production binary (a Lambda bot: ~35 HTTPS requests + a 7.7 MB lazy JSON parse per
  invocation): deterministic crash on Lambda; locally the same binary crashes in ~20 s
  when its requests are connection-refused (rapid retries = many socket_callbacks
  interleaved with allocation-driven GCs).
- Minimal reproducer (**verified**): a trimmed binary looping { one HTTP request to a
  refused port via Downloads; `GC.gc()` } segfaults on the *first* iteration —
  "Allocations: 707 ... GC: 1", crash in the Downloads timer-callback task. ~20 lines.
- rr trace of the production binary available: crash, watchpoint, and reverse
  execution exactly as described.

Red herring warning for future readers: this resisted an extensive
environment-elimination campaign (AL2023 chroot, QEMU microvm with a firecracker CI
kernel and a real 1 GB limit, rr chaos mode, SIGSTOP CPU throttling, io_uring disabled,
2-CPU pinning — all clean) because the trigger is purely allocation/GC timing relative
to socket_callback activity, which varied with the binary and workload, not the
environment.

## Resolution

- **Mechanism pinned down**: `--trim` strips module binding tables (only modules,
  `__init__`s and a few special functions survive in `jl_queue_module_for_serialization`),
  so `FDWatchers` — a `let`-captured Vector reachable only through native-code gvar
  slots, which are not GC roots — is unreachable from the root set and never marked.
  Image objects load as `GC_OLD | GC_IN_IMAGE` (*unmarked* old), and `jl_gc_wb` only
  arms for `GC_OLD_MARKED` parents: the write barrier can never fire. Verified
  in-binary (mark bit still clear after 3 collections) and in the rr trace
  (header nibble `0x6` at crash time).
- **Fixed upstream, accidentally**: JuliaLang/julia#61474 ("GC: permanently mark
  pkg/sysimage objects to speed up GC", merged 2026-05-21, labeled *performance*)
  loads image objects `GC_OLD_MARKED | GC_IN_IMAGE` with a persistent image remset —
  barrier armed from birth. Backported to `release-1.13` in #62009; **first release
  with the fix is 1.13.0-rc2**. Julia 1.12.6 (current stable, ships juliac) is still
  affected (verified crashing). Validation: repros crash 3/3 on 1.13.0-rc1 and
  1.12.6, survive 3/3 on release-1.13 (rc2) and master.
- **Regression test PR** (the fix currently has no test guarding the invariant):
  `KenoAIStaging/julia` branch `trimming-test-image-gc-write-barrier` (off
  `release-1.13`); a working 1.12 backport of #61474 + test sits on
  `backport-1.12-image-gc-write-barrier`.
- **Workaround history**: a compile-time pre-grow of the FDWatchers table (bake a
  large backing Memory into the image so the runtime never `resize!`s the unrooted
  vector) validated cleanly in local harnesses but the CI-built production Lambda
  still crashed with the original signature — the defect class is broader than any
  single site, so the workaround was dropped in favor of the real fix: **the
  bundles now build on the `1.13-nightly` channel** (release-1.13 nightlies carry
  #62009; switch back to `'1.13'` once rc2+ binaries are published). Validated on
  1.13.0-rc1.105: stock repro survives 3/3, bundle survives 793k-retry
  connection-refused churn and 5/5 replayed 24,382-job report generations.
- **Nightly fallout worth an upstream look**: post-rc1 builds serialize the
  sysimage-resident BLAS stack's module `__init__`s into trimmed images that never
  reference LinearAlgebra (rc1 dropped them), so the pruned bundle died in
  `OpenBLAS_jll.__init__` at startup; the prelude now stubs those inits at compile
  time. Possibly a side effect of #61474's serializer changes.

## Also hit while debugging (candidates for separate issues)

- Fatal-signal reports for faults on threads without a Julia task context print no
  frames and no ip (fix prepared: `KenoAIStaging/julia` branch
  `crash-report-foreign-threads`).
- `--trim=safe` verifier rejects `Base.lpad` and `DateTime(::String, ::DateFormat)`;
  Parsers.jl float paths verify only with a compat-override prelude.
