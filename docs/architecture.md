# How the farm fits together

Two views: the pieces and how they talk, then the life of one run. Details of
sealing (the compile cache) are in [sealing.md](sealing.md).

## Components

```mermaid
flowchart LR
    gh["GitHub<br/>@pkgeval comments on JuliaLang/julia"]
    bk["Buildkite<br/>julia-build-request pipeline"]
    site["Site (GitHub Pages)<br/>reports and dashboard"]
    ext["Other workers<br/>(any Linux machine)"]

    subgraph aws["AWS (us-east-2)"]
        bot["pkgeval-bot Lambda<br/>webhook, runs-table stream, hourly poll,<br/>daily run, reports, DLQ consumer,<br/>5-min fleet load sample"]
        broker["pkgeval-broker Lambda<br/>GitHub login to STS credentials"]
        breq["pkgeval-build-request Lambda"]

        subgraph state["DynamoDB"]
            runs[("pkgeval-runs<br/>user, seal and deriv runs,<br/>_fleet-generation")]
            jobs[("pkgeval-jobs<br/>one item per config and package")]
            builds[("pkgeval-builds")]
        end

        subgraph queues["SQS (workers claim deriv, seal, slow, jobs, in that order)"]
            qderiv[["deriv"]]
            qseal[["seal"]]
            qslow[["slow<br/>long jobs and expand messages"]]
            qjobs[["jobs"]]
            dlq[["dlq"]]
        end

        s3[("S3 pkgeval<br/>logs, reports, compile cache store,<br/>fleet load history")]

        subgraph fleet["ASG pkgeval-ec2-worker (spot, scales on queue backlog)"]
            subgraph host["each instance"]
                worker["worker process<br/>one slot per vCPU, plus spill<br/>and donor slots for seal work"]
                proxy["cache proxy<br/>(loopback)"]
                sandbox["PkgEval sandboxes<br/>with the cache client"]
            end
        end
    end

    gh -->|"@pkgeval command"| bot
    bot -->|"status comments, report"| gh
    bot -->|"create run"| runs
    bot -->|"expand message"| qslow
    bot -->|"reports"| s3
    runs -.->|"run finished (stream)"| bot
    dlq -->|"errors recorded, build waits recycled"| bot
    qderiv & qseal & qslow & qjobs -->|claim| worker
    worker -->|"job status, heartbeat"| jobs
    worker -->|"logs, results, published cache files"| s3
    worker -->|"missing Julia build"| breq
    breq --> bk
    breq --> builds
    worker -->|"runs PkgEval"| sandbox
    sandbox -->|"POST /ensure (cache fetch)"| proxy
    proxy -->|"cached artifacts"| s3
    proxy -->|"derivation (when all its deps are published)"| qderiv
    ext -->|"device-flow login"| broker
    ext -->|claim| queues
    site -->|"reports"| s3
    site -->|"run list (anonymous Cognito)"| runs
    site -->|"queue depths"| queues
```

- **DynamoDB is the source of truth.** SQS only dispatches, and every claim is a
  conditional write on the job item, so duplicate messages are harmless.
- **Workers are stateless.** A worker that dies stops heartbeating, and its jobs
  reappear on the queue. A stopped worker hands its claims back before exiting.
- **The slow queue** takes a run's longest jobs. Workers drain it before the
  fast queue, so short work backfills behind the long jobs and the end of the
  run is not held up by one late straggler.
- **The daily run** replaces Nanosoldier's daily PkgEval: the bot submits it
  and writes a `daily.json` in Nanosoldier's format, which the site reads.
- **Deploys:** pushes to master build the Lambda bundles and the worker
  sysimage (which bakes in PkgEval master as of the build) in CI. Workers boot
  from the commit pinned by the `_fleet-generation` record, which only moves on
  once no worker has kept it alive for 10 minutes, i.e. the fleet has scaled to
  zero. Infrastructure is applied by hand with `tofu apply`; the state lives in
  S3.

## Life of a run

```mermaid
sequenceDiagram
    autonumber
    participant B as bot
    participant Q as SQS
    participant W as worker slot
    participant D as DynamoDB
    participant P as cache proxy
    participant S as sandbox (PkgEval)

    B->>D: create run (configs, packages)
    B->>Q: expand message (slow queue)
    W->>Q: claim expand
    W->>D: write test jobs, reuse baseline results,<br/>find or create the shared seal run for each configuration
    W->>Q: seal jobs whose deps are sealed (seal queue)
    W->>Q: test jobs, longest to the slow queue

    loop every free slot, in queue priority order
        W->>Q: claim a seal job
        W->>S: precompile the package's test environment
        Note over W: publish the package's cache file to the store (S3)
        W->>D: seal job done, queue dependents now ready
    end

    W->>Q: claim a test job
    W->>D: is its package's seal job done?
    alt still pending
        W->>Q: put it back, delayed 5 min (claim undone)
        Note over W,Q: runs anyway after 6 h,<br/>or once its seal job has stalled
    else sealed (or no seal job)
        W->>S: evaluate (install, precompile, test)
        S->>P: fetch each dependency's cache file
        alt in the store
            P-->>S: cache file
        else derivable: all of its deps are published
            P->>D: derivation run and job
            P->>Q: derivation job (deriv queue)
            Note over P,S: request held until the derivation is done<br/>or the client's 10 min deadline. Held time<br/>does not count against the time limit
            P-->>S: cache file, or 404 (compile locally)
        else not derivable
            P-->>S: 404 at once (compile locally)
        end
        S-->>W: status and log
        W->>D: record result, run completion counter
    end

    D-->>B: run flipped to done (table stream, hourly poll as fallback)
    B->>B: write the report to S3, post it to GitHub
```

- **Time limit:** about 45 minutes per test, plus up to 30 minutes of held cache
  fetches. Kills at the limit are recorded as `kill`.
- **Retries:** a job whose evaluation fails for infrastructure reasons is handed
  back and retried. The second and later attempts skip the cache and the seal
  gate, and the third records its result whatever it is.
- **Stopping a worker** (spot notice, scale-in, service restart) hands its claims
  back first. Results that finish while it exits are not recorded.
