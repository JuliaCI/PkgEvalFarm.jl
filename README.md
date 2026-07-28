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
  (@pkgeval │                                                  │      (any Linux box,
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
- **Submission** is decoupled: the `@pkgeval` bot (or a human with the CLI)
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
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/JuliaCI/PkgEvalFarm.jl")'
farm login              # GitHub device flow; requires membership in the workers team
farm worker             # pulls jobs until stopped; --ninstances to bound parallelism
```

`farm` is a Julia 1.12 [app](https://pkgdocs.julialang.org/dev/apps/): the shim
lands in `~/.julia/bin`. From a checkout, `bin/farm <cmd>` (or
`julia --project -m PkgEvalFarm <cmd>`) is equivalent.

A worker needs no configuration at all: the broker lives at its built-in default
`https://pkgeval.julialang.org` (`--broker` or `PKGEVAL_FARM_BROKER` override it,
e.g. for a staging deployment), and everything else (queue URL, table names,
bucket, region) is handed out by the broker after authentication.

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

## Worker requirements

Same as PkgEval.jl: Linux (x86_64/aarch64), cgroup v2 with delegated controllers,
unprivileged user namespaces, and enough disk for the rootfs/compile caches. Run **one
worker process per machine** (PkgEval's shared caches are guarded by in-process locks);
scale within the machine via `--ninstances`.

## Deploying

1. Create a **GitHub OAuth app** (Settings → Developer settings → OAuth Apps) for the
   farm. Enable *Device Flow*; no callback URL or client secret is needed — the broker
   never holds GitHub secrets. Note the client id.
2. Create the two GitHub teams (default `pkgeval-workers` and `pkgeval-submitters`) in
   your org. Membership in these teams is what authorizes people; enrolling a new
   worker operator is just a team invite.
3. Build the broker and apply the terraform:

```sh
julia +1.13 --project=broker broker/build/build.jl   # produces broker/build/bootstrap.zip
cd terraform
tofu init && tofu apply                              # or terraform
```

The `broker_dns_records` output lists the DNS records that point
`pkgeval.julialang.org` at the broker (the zone is hosted outside AWS); with
those in place, workers need no configuration at all. See `terraform/README.md`
for all variables.

## Running the bot

The `@pkgeval` bot is a second juliac-compiled Lambda with three triggers:

1. a **GitHub webhook** (`issue_comment` events, HMAC-verified against
   `github_webhook_secret`) delivered to its Function URL — commands are handled the
   moment they are posted;
2. the **DynamoDB stream** of the runs table, filtered to runs flipping to `done` —
   reports are posted the moment the last job finishes;
3. an infrequent **scheduled poll** of the bot account's notifications (default:
   hourly) as a fallback for missed webhook/stream deliveries — and as the sole
   mechanism when no webhook can be registered (a webhook needs admin on the target
   repo/org; polling needs no permissions there at all, which is why the original
   Nanosoldier polled). The poll also refreshes each in-flight run's submission
   comment in place with progress and an ETA, so a run occupies exactly one
   comment: the ack, the hourly status edits, and finally the report all land in
   it (the requester is still notified — GitHub pings on mentions an edit adds).

It is created by the same terraform when `github_bot_token` is set (register the
`bot_webhook_url` output as an `issue_comment` webhook, content type JSON, with the
same secret). Its execution role carries the submitter policy directly — no broker
hop, no long-running server.

Mention it on a PR: `@pkgeval runtests()`, `runtests(["Foo"])`, or
`runtests(vs = ":master")`. Commands are only executed for authorized authors —
by default active members of the submitter team, or (with
`bot_submitter_team = ""`) any org member. Classic Nanosoldier's collaborator
check was disabled in 2021, leaving it open to any commenter; this bot
deliberately does not replicate that.

**Missing Julia builds**: workers never compile Julia from source. A config
whose Julia is not staged in the CI buckets (`julialang-ephemeral-{ci,pr,request}`)
surfaces as `MissingStagedBuild` during expansion; the worker asks the
build-request Lambda (SigV4, its own credentials) to have the
`julia-build-request` Buildkite pipeline build that exact commit into the
request bucket, and releases the expand message for retry. The Lambda holds
the (pipeline-scoped) Buildkite token in SSM and deduplicates requests.

**Straggler avoidance**: long jobs are routed to a separate slow queue that
workers drain first, so they start while plenty of short work remains to
backfill behind them; the duration cutoff is computed per run from estimates
out of recent completed runs. The end-of-run tail is thereby bounded by the
cutoff instead of by the slowest package.

**Baseline reuse**: when the `against` side of a run is an exact commit or
release that an earlier completed run also evaluated (with identical settings),
those results are reused instead of re-evaluated — the bot pins branch specs
like `vs = ":master"` to a sha at submission precisely so this can match. The
report notes which run the baseline came from. If the existing baseline looks
flaky, force a re-evaluation with `runtests(..., fresh_baseline = true)` (CLI:
`farm submit --fresh-baseline ...`). Moving specs that stay unpinned (a plain
`nightly`) are never reused.

The identical bot code also runs interactively anywhere (state lives in the runs
table and GitHub, so Lambda and interactive bots can even coexist):

```sh
export BOT_GITHUB_TOKEN=...            # token of the bot account (the Lambda
                                       # reads it from SSM instead, see bot.tf)
bin/farm login                          # operator must be in the submitters team
bin/farm bot
```

Package-list expansion never happens in the bot: submission stores the request and
the first worker to pick it up fans out the jobs (computing the "all compatible
packages" set needs the Julia build under test, which only workers have).
