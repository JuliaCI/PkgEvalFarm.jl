# Draft issue: juliac --trim binary — GC mark thread segfaults on AWS Lambda

**Environment:** juliac binary (`--experimental --trim=safe`, `JULIA_CPU_TARGET=sandybridge`),
Julia 1.13.0-rc1, AWS Lambda `provided.al2023` (firecracker, 1024 MB), x86_64.

**Crash (every invocation that runs the workload; container cold each time):**

```
[2] signal 11 (1): Segmentation fault
in expression starting at none:0
Allocations: 1318316 (Pool: 1318267; Big: 49); GC: 2
```

No backtrace frames at all between the header and the stats line. Workload: lazily
parsing a ~7.7 MB / 24k-item DynamoDB response (JSON.jl lazy API); ~1.3 M allocations,
crash consistently around the 2nd collection, ~130 MB RSS. Earlier the same workload
showed two 300 s hangs (88 MB used) — possibly the same defect as a wedge.

## Thread [2] identified: the GC mark helper

Cold-start diagnostics deployed into the production function report:

```
total_memory=1249447936 physical_memory=1249447936 cpu_threads=2 nthreads=1 ngcthreads=1
```

- Memory is read *correctly*: ~1.19 GB = the microVM's RAM (function 1024 MB + overhead),
  total == physical, no cgroup layer. GC heuristics see the true limit.
- Julia TLS threads: main + **one GC mark thread** (`ngcthreads=1`). gdb on an identical
  local binary shows the mark thread parking in the *scheduler* between collections
  (`task_done_hook → poptask → ijl_task_get_next`), as expected for modern GC threads.
- ⇒ `[2]` is the mark helper; it dies during a collection. The absent backtrace suggests
  the fault may be in/around the signal–safepoint path on that thread (sigaltstack /
  handler state in the trimmed image?) rather than in unwindable mark-loop code.

## Extensive non-reproduction outside Lambda (same binary recipe, same data)

All clean, 5 full parses per run:

| variation | runs |
|---|---|
| default (Debian glibc, 811 GB visible) | many |
| `JULIA_HEAP_SIZE_HINT` 30–150 M (verified honored: full-sweep count doubles) | several |
| `taskset -c 0,1` (2 CPUs, as Lambda) | 10 |
| rr `--chaos`, `JULIA_NUM_GC_THREADS=4`, 100 M hint | 15 |
| AL2023 rootfs chroot (glibc 2.34), plain | 1 |
| AL2023 chroot + rr chaos + 4 GC threads | 15 |
| SIGSTOP/CONT 57 % duty cycle (Lambda CPU-share emulation), AL2023, 4 GC threads | 12 |
| live-HTTPS variant (real DynamoDB paging through curl during parse) | 1 |
| full `lambda_loop` against stub runtime API + response replay | 1 |

GC cadence locally matches Lambda (~2 pauses per parse), so collection-during-parse is
the *common* case, not the discriminator.

Remaining environmental deltas: firecracker virtual hardware; io_uring — locally libuv
runs an `iou-sqp` SQPOLL kernel thread, while Lambda's sandbox blocks io_uring, forcing
libuv's threadpool fallback (different wakeup paths into the same scheduler the mark
thread parks in).

## Discriminating experiment staged

`JULIA_NUM_GC_THREADS=0` on the production function — this *removes thread [2]*.
Crashes stopping implicates the mark helper (rooting view / safepoint handling / mark
loop in the trimmed image); crashes moving to another thread implicates the signal
machinery generally. Result pending.

Also hit separately (likely distinct issues): `--trim=safe` verifier rejects `Base.lpad`
and `DateTime(::String, ::DateFormat)`; a minimal entrypoint including the same modules
trips 8 Parsers.jl float-path verifier errors that the production entrypoint (with its
compat-override prelude) does not.

Reproducer harness (parse driver, captured payloads, stub runtime API, replay server)
available.
