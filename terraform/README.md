# PkgEvalFarm infrastructure

Terraform/OpenTofu configuration for the PkgEvalFarm backend: a distributed
PkgEval job farm consisting of a job queue (SQS), run/job state tables
(DynamoDB), a results bucket (S3), and a small "broker" Lambda that hands out
temporary AWS credentials to authorized GitHub users.

## Architecture

- **`<prefix>-runs` / `<prefix>-jobs` (DynamoDB)** — one item per PkgEval run,
  and one item per (run, package) job.
- **`<prefix>-jobs` (SQS)** — queue that workers poll for jobs; messages that
  fail to be processed 4 times land in `<prefix>-jobs-dlq`.
- **Results bucket (S3)** — workers upload logs/artifacts and submitters
  publish reports under `runs/<run_id>/...`. Objects under `runs/` expire
  after 180 days. If `public_reports` is true (the default),
  `runs/*/report/*` and `runs/*/logs/*` are publicly readable.
- **`<prefix>-broker` (Lambda)** — exposed via a public Lambda function URL.
  It performs the GitHub OAuth *device flow*, checks the user's team
  membership in `github_org`, and vends temporary credentials by assuming the
  `<prefix>-worker` or `<prefix>-submitter` IAM role (scoped to exactly the
  queue/tables/bucket operations each side needs).
- **`<prefix>-bot` (Lambda, optional)** — the `@nanosoldier2` bot. Created only
  when `github_bot_token` is set. Its execution role carries the submitter
  policy directly, so it needs neither the broker nor team membership.
  Triggers: a Function URL receiving HMAC-verified GitHub `issue_comment`
  webhooks (when `github_webhook_secret` is set; register the
  `bot_webhook_url` output on the target repo/org — requires admin there), the
  runs table's DynamoDB stream (filtered to `status = "done"`) for report
  posting, and an EventBridge schedule (`bot_schedule`, default hourly) as a
  notifications-polling fallback.

## Enrollment and authorization

There is no per-machine registration and no long-lived secrets:

- Authorization is entirely driven by **GitHub team membership**. Members of
  the `worker_team` team in `github_org` may enroll worker machines; members
  of `submitter_team` may submit runs.
- **Adding a worker operator = adding them to the GitHub team.** Removing them
  from the team revokes access as soon as their current temporary credentials
  (default 1 hour, see `cred_duration_seconds`) expire.
- When a worker (or submitter) starts, it runs the GitHub device flow against
  the OAuth app identified by `github_client_id`, sends the resulting user
  token to the broker, and receives short-lived AWS credentials plus the
  queue/table/bucket configuration.
- **The broker function URL is the only thing workers need to be given** —
  all other configuration (queue URL, table names, bucket, region) is served
  by the broker itself.

## EC2 workers (testing and burst capacity)

The config can run self-enrolling EC2 workers as a spot-first auto-scaling
group:

```sh
tofu apply -var ec2_worker_count=4    # scale up
tofu apply -var ec2_worker_count=0    # scale to zero (default)
```

All-spot by default (`ec2_worker_on_demand_percent = 0`): spot interruption is
harmless — the killed worker's jobs stop being heartbeated and SQS redelivers
them — and the ASG replaces interrupted instances automatically
(`price-capacity-optimized` across `ec2_worker_instance_types`, default
m6a/m6i/m5a/m7a 8xlarge: 32 vCPU with 4 GB/vCPU headroom for heavy package
tests; larger instances amortize the per-machine Julia build and caches).

Being inside AWS they skip GitHub enrollment entirely — an instance profile
carries the same worker policy the broker would vend, and cloud-init installs
juliaup + PkgEvalFarm.jl (`ec2_worker_farm_repo`/`_ref`) and starts a
`pkgeval-worker` systemd unit with the cgroup/userns settings PkgEval needs.
No SSH ingress; debug with `aws ssm start-session --target <instance-id>`
(worker logs via `journalctl -u pkgeval-worker`).

## Variables

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `name_prefix` | no | `"pkgeval"` | Prefix for naming all resources. |
| `region` | no | `"us-east-1"` | AWS region to deploy into. |
| `bucket_name` | **yes** | — | S3 bucket for PkgEval results. |
| `github_org` | **yes** | — | GitHub organization whose teams gate access. |
| `worker_team` | no | `"pkgeval-workers"` | Team slug allowed to run workers. |
| `submitter_team` | no | `"pkgeval-submitters"` | Team slug allowed to submit runs. |
| `github_client_id` | **yes** | — | Client ID of the public GitHub OAuth app used for the device flow. |
| `cred_duration_seconds` | no | `3600` | Lifetime of the temporary credentials the broker vends. |
| `public_reports` | no | `true` | Make `runs/*/report/*` and `runs/*/logs/*` publicly readable. |
| `github_bot_token` | no | `""` | Token of the bot's GitHub account; empty disables the bot Lambda. |
| `github_webhook_secret` | no | `""` | Secret for GitHub webhook verification; empty disables the webhook endpoint. |
| `bot_name` | no | `"nanosoldier2"` | GitHub handle the bot answers to. |
| `bot_schedule` | no | `"rate(1 hour)"` | EventBridge schedule for fallback bot polls. |
| `ec2_worker_count` | no | `0` | Desired EC2 workers (testing/burst; 0 = none). |
| `ec2_worker_max` | no | `16` | ASG upper bound. |
| `ec2_worker_instance_types` | no | m6a/m6i/m5a/m7a `8xlarge` | Spot pool candidates, in preference order. |
| `ec2_worker_on_demand_percent` | no | `0` | Share of capacity on-demand instead of spot. |
| `ec2_worker_disk_gb` | no | `200` | Worker root volume (GB). |
| `ec2_worker_farm_repo` / `_ref` | no | staging repo, `master` | Where EC2 workers clone PkgEvalFarm.jl from. |
| `ec2_worker_julia_channel` | no | `"1.12"` | juliaup channel installed on EC2 workers. |

## Deploying

1. **Build the Lambda zips first.** The Lambda resources package
   `broker/build/bootstrap.zip` (and `bot/build/bootstrap.zip` when the bot is
   enabled), which are not checked in; from the repository root run:

   ```sh
   julia +1.13 --project=broker broker/build/build.jl
   julia +1.13 --project=bot bot/build/build.jl        # only if enabling the bot
   ```

   (`tofu validate` works without the zips, but `plan`/`apply` require them.)

2. Deploy:

   ```sh
   cd terraform
   tofu init
   tofu apply -var bucket_name=<bucket> -var github_org=<org> -var github_client_id=<client-id>
   ```

3. Note the `broker_function_url` output and hand it to worker operators and
   submitters — that URL is all they need.

Re-run steps 1–2 whenever the broker code changes; the `source_code_hash`
picks up the new zip automatically.
