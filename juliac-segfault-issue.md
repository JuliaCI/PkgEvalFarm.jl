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

## Also hit while debugging (candidates for separate issues)

- Fatal-signal reports for faults on threads without a Julia task context print no
  frames and no ip (fix prepared: `KenoAIStaging/julia` branch
  `crash-report-foreign-threads`).
- `--trim=safe` verifier rejects `Base.lpad` and `DateTime(::String, ::DateFormat)`;
  Parsers.jl float paths verify only with a compat-override prelude.
