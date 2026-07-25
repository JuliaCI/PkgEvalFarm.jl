# PkgEvalFarm.jl

Distributed, elastically-scalable orchestration for [PkgEval.jl](https://github.com/JuliaCI/PkgEval.jl).

PkgEval evaluates the whole Julia package ecosystem against Julia builds. Historically it
ran on a single large machine driven by Nanosoldier. PkgEvalFarm replaces the
single-machine orchestration with a cloud queue so that worker machines can be added and
removed at will, while PkgEval.jl itself keeps doing the actual sandboxed evaluation on
each worker.

## Architecture

```
                 ┌─────────────────────────────────────────────────┐
                 │                     AWS                          │
  submitter ───▶ │  DynamoDB (runs, jobs)      SQS (job queue+DLQ) │ ◀─── worker
  (@nanosoldier2 │                                                  │      (any Linux box,
   bot or CLI)   │  S3 (results, logs, reports)                     │       enrolled via
                 │                                                  │       GitHub login)
                 │  Lambda: credential broker (juliac-compiled)     │
                 └─────────────────────────────────────────────────┘
```

- **State** lives in two DynamoDB tables: `runs` (one item per submitted evaluation
  run) and `jobs` (one item per `(configuration, package)` pair). DynamoDB is the
  source of truth; SQS is only a dispatch mechanism.
- **Dispatch** is an SQS standard queue. One message = one job. At-least-once delivery
  is made safe by conditional writes in DynamoDB (a finished job is never re-run).
  A dead-letter queue catches jobs that repeatedly kill workers.
- **Results** (a small JSON record + the test log per job, plus aggregated reports)
  go to S3.
- **Workers** are stateless daemons (`bin/farm worker`). Any authorized person can
  enroll a machine: the worker logs in with the GitHub OAuth *device flow*, and a small
  **credential broker** (a Julia Lambda, statically compiled with `juliac`) verifies
  GitHub team membership and vends short-lived, least-privilege STS credentials
  (receive/delete queue messages, update job items, `PutObject` under `runs/` — nothing
  else). Credentials auto-refresh through the broker; revoking a person's team
  membership cuts off their workers within the hour.
- **Submission** is decoupled: the `@nanosoldier2` bot (or a human with the CLI)
  authenticates the same way but through a separate GitHub team, receiving a
  broader "submitter" role that can create runs and write reports.

There are deliberately **no long-running servers**: the broker is a Lambda, the bot is
a poller that can run anywhere (even a cron job), and workers only need outbound HTTPS.

## Components

| Path         | What                                                              |
|--------------|-------------------------------------------------------------------|
| `src/`       | The `PkgEvalFarm` package: schema, queue layer, auth, worker, submit, report, bot |
| `broker/`    | The credential broker Lambda (separate juliac-compiled project)   |
| `terraform/` | All AWS resources (tables, queue, bucket, IAM, Lambda)            |
| `bin/farm`   | CLI entry point (`login`, `submit`, `worker`, `status`, `report`, `bot`) |

## Enrolling a worker

On any Linux x86_64/aarch64 machine that meets PkgEval's requirements (cgroup v2,
unprivileged user namespaces):

```sh
bin/farm login          # GitHub device flow; requires membership in the workers team
bin/farm worker         # pulls jobs until stopped; --ninstances to bound parallelism
```

The only configuration a worker needs is the broker URL (`--broker` or
`PKGEVAL_FARM_BROKER`); everything else (queue URL, table names, bucket, region) is
handed out by the broker after authentication.

## Submitting a run

```sh
bin/farm submit --primary 'JuliaLang/julia#master' --against 'v1.12.0' [pkg...]
bin/farm status <run-id>
bin/farm report <run-id>    # aggregate results into a Nanosoldier-style report
```

## Job lifecycle

1. `submit` writes the `runs` item and batch-writes `jobs` items (status `pending`),
   then enqueues one SQS message per job.
2. A worker receives a message, conditionally flips the job to `running` in DynamoDB
   (skipping jobs that are already done — SQS is at-least-once), and starts a PkgEval
   evaluation. While evaluating it extends the SQS visibility timeout as a heartbeat,
   so a crashed/killed worker's jobs simply reappear on the queue.
3. On completion the worker uploads `runs/<run>/logs/<config>/<pkg>.log` and the result
   record to S3, updates the job item (final status: `ok`/`fail`/`crash`/`kill`/`skip`
   + reason), increments the run's completion counter, and deletes the SQS message.
4. When the counter reaches the total, whoever wants the report runs the aggregation
   (the bot does this automatically and posts back to GitHub).

## Deploying

```sh
cd terraform
tofu init && tofu apply    # or terraform
cd ../broker && julia --project build/build.jl && cd ../terraform && tofu apply
```

See `terraform/README.md` for the variables (GitHub org/teams, OAuth client id, ...).
