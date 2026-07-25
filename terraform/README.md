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
group **that scales itself off the job queue**:

```sh
tofu apply -var ec2_worker_max=4    # enable, with a hard capacity ceiling
tofu apply -var ec2_worker_max=0    # tear down (default)
```

Scaling within `[ec2_worker_min, ec2_worker_max]` is automatic and designed
not to overshoot:

- **out**: proportional to the visible backlog per in-service worker
  (`ec2_worker_backlog_target`, default 400 jobs), scale-out *only*, so a
  draining queue never churns busy workers; a 15-minute instance warmup stops
  the scaler from over-ordering while machines boot. From zero, a kickstart
  policy starts exactly one worker when the queue turns non-empty — that
  worker also expands the run, so capacity follows the real job count.
- **in**: only to the floor, and only after the queue has been completely
  idle — nothing visible *or in flight* — for `ec2_worker_idle_minutes`
  (default 15), so the long tail of slow jobs is never cut short.
- `ec2_worker_max` is validated to ≤ 4 for now as a cost guardrail; raise the
  cap in `variables.tf` deliberately when a bigger fleet is intended. Set
  `ec2_worker_min = ec2_worker_max` to pin fixed capacity.

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

**IMDS protection**: PkgEval sandboxes share the host network namespace, so
package code under test could otherwise reach the instance metadata service
and steal the worker-role credentials. Cloud-init therefore firewalls IMDS to
root only (`iptables` uid-owner rule) and runs a root-owned localhost proxy
that re-serves the credentials gated on a bearer token. The token reaches the
worker via a root:worker-readable systemd `EnvironmentFile`; the sandbox
inherits neither the worker's environment nor host files, so it can reach the
proxy's port but never authenticate. Network-namespace isolation in PkgEval
itself would still be a welcome belt-and-braces improvement.

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
| `bot_submitter_team` | no | `null` | Team gating bot commands (null = `submitter_team`; `""` = any org member). |
| `github_webhook_secret` | no | `""` | Secret for GitHub webhook verification; empty disables the webhook endpoint. |
| `bot_name` | no | `"nanosoldier2"` | GitHub handle the bot answers to. |
| `bot_schedule` | no | `"rate(1 hour)"` | EventBridge schedule for fallback bot polls. |
| `ec2_worker_max` | no | `0` | EC2 worker ceiling (0 = disabled; validated ≤ 4 for now). |
| `ec2_worker_min` | no | `0` | EC2 worker floor (= max to pin capacity). |
| `ec2_worker_backlog_target` | no | `400` | Visible jobs per worker the scaler aims for. |
| `ec2_worker_idle_minutes` | no | `15` | Full queue idle time before scaling to the floor. |
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

## Build portability note

The Lambda bundles are compiled for the `sandybridge` CPU target
(`JULIA_CPU_TARGET`, overridable). Without that, `juliac` targets the *build
host's* CPU: on a modern machine that bakes in AVX-512, which Lambda's
microVMs mask, and the function dies during init with

```
ERROR: Unable to find compatible target in cached code image.
Target 0 (znver4): Rejecting this target due to use of runtime-disabled features
```

Verify a build with `objdump -d broker/build/stage/bootstrap | grep -c '%zmm'`
— it must be 0.

## CI/CD

`.github/workflows/ci.yml` runs the test suite on every push/PR, builds both
Lambda bundles (asserting they contain no AVX-512, see above), and — only for
pushes to `master` — publishes them to AWS.

Deployment uses **GitHub Actions OIDC**: no AWS keys are stored anywhere. The
workflow mints a short-lived OIDC token, and `${prefix}-deploy` (created here)
trusts it only for the `sub` claims in `github_deploy_subjects` — by default the
`master` branch of the deploy repo, so forks and pull requests cannot assume it.
The role may only write to the Lambda bucket and call `UpdateFunctionCode` on
`${prefix}-*` functions.

The deploy coordinates live in the workflow's own `env:` block — none of them
are secrets (an account id, a role ARN, a bucket name and a public function
URL), so there is nothing to configure in repository settings. After a
redeployment, refresh them from the terraform outputs:

| Workflow `env` | Output |
| -------------- | ------ |
| `AWS_DEPLOY_ROLE` | `deploy_role_arn` |
| `AWS_REGION` | `region` |
| `LAMBDA_BUCKET` | `lambda_bucket` |
| `NAME_PREFIX` | `name_prefix` |
| `BROKER_URL` | `broker_function_url` (empty disables the post-deploy smoke test) |

Check whether the account already has a GitHub OIDC provider (only one per
issuer URL is allowed; pass its ARN as `github_oidc_provider_arn` if so):

```sh
aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')].Arn" \
  --output text
```

### What the trust policy is keyed on

IAM maps a **fixed set** of GitHub claims to condition keys: `actor`,
`actor_id`, `job_workflow_ref`, `repository`, `repository_id`,
`repository_owner_id`, `workflow`, `ref`, `environment`, `enterprise_id`, plus
the standard `aud`/`sub`/`amr`
([docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#condition-keys-wif)).
A condition on any *other* claim — `event_name`, `runner_environment`,
`repository_owner`, `workflow_ref` — can never match, so the role becomes
unassumable and STS returns a bare `Not authorized to perform
sts:AssumeRoleWithWebIdentity` with no indication of which condition failed.

| Claim | Condition | Why |
| ----- | --------- | --- |
| `aud` | `= sts.amazonaws.com` | a token minted for another audience can't be replayed here |
| `repository_id` | `= github_repository_id` | immutable: survives renames, and the path can't be re-claimed after deletion |
| `repository_owner_id` | `= github_repository_owner_id` | ditto for the owner |
| `ref` | `= github_deploy_ref` | only the deploy branch |
| `job_workflow_ref` | `= github_deploy_workflow_ref` | only *this* workflow file; a new workflow on the branch doesn't inherit the grant |

`sub` is deliberately unused (`github_deploy_subjects` is empty): its format is
org-configurable — this org emits the immutable variant,
`repo:OWNER@<owner_id>/REPO@<repo_id>:ref:refs/heads/master` — and the claims
above pin the same facts in a format GitHub can't reconfigure underneath us.

Forks and pull requests are excluded by `ref`: a PR run carries
`ref=refs/pull/N/merge`. Belt and braces, GitHub caps fork-PR permissions at
read-only, so such a job cannot mint a token at all, and the deploy job's `if:`
refuses to run outside a push to the deploy branch. Guards IAM cannot express
(only on `push`, only on a GitHub-hosted runner) live in that `if:` and should
be backed by branch protection.

Note `job_workflow_ref` pins the file path — renaming `ci.yml` or moving the
deploy job into a reusable workflow breaks deploys until the variable is
updated. To see the claims a run actually mints:

```yaml
- run: |
    tok=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
    echo "$tok" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
```

Terraform bootstraps the initial bundles and then defers to CI: the zip objects
and the functions' `source_code_hash` carry `ignore_changes`, so a later
`tofu apply` from a stale checkout will not roll back a CI-published bundle.
