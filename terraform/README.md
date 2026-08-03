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
- **`<prefix>-bot` (Lambda, optional)** — the `@pkgeval` bot. Created only
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

Capacity is denominated in **job slots** (= vCPUs): the mixed-instances
overrides are weighted by vCPU count, so the fleet may mix instance sizes and
the spot allocator compares pools by price *per slot*.

```sh
tofu apply -var ec2_worker_max=384  # enable, with a hard slot ceiling
tofu apply -var ec2_worker_max=0    # tear down (default)
```

Scaling within `[ec2_worker_min, ec2_worker_max]` is automatic and designed
not to overshoot:

- **out**: proportional to the visible backlog per in-service slot
  (`ec2_worker_backlog_target`, default 12.5 jobs/vCPU), scale-out *only*, so a
  draining queue never churns busy workers; a 15-minute instance warmup stops
  the scaler from over-ordering while machines boot. From zero, a kickstart
  policy starts exactly one worker when the queue turns non-empty — that
  worker also expands the run, so capacity follows the real job count.
- **in**: only to the floor, and only after the queue has been completely
  idle — nothing visible *or in flight* — for `ec2_worker_idle_minutes`
  (default 15), so the long tail of slow jobs is never cut short.
- `ec2_worker_max` is validated to ≤ 384 slots for now as a cost guardrail;
  raise the cap in `variables.tf` deliberately when a bigger fleet is intended.
  Set `ec2_worker_min = ec2_worker_max` to pin fixed capacity.

All-spot by default (`ec2_worker_on_demand_percent = 0`): spot interruption is
harmless — the killed worker's jobs stop being heartbeated and SQS redelivers
them — and the ASG replaces interrupted instances automatically
(`price-capacity-optimized` across `ec2_worker_instance_types`, default M
types from 8xlarge to 24xlarge, all 4 GB/vCPU for heavy package tests; with
vCPU weights the allocator lands on a large size exactly when it is cheaper
per slot, and larger instances also amortize the per-machine Julia build and
caches better).

Being inside AWS they skip GitHub enrollment entirely — an instance profile
carries the same worker policy the broker would vend, and cloud-init installs
juliaup + PkgEvalFarm.jl (`ec2_worker_farm_repo`/`_ref`) and starts a
`pkgeval-worker` systemd unit with the cgroup/userns settings PkgEval needs.
No SSH ingress; debug with `aws ssm start-session --target <instance-id>`
(worker logs via `journalctl -u pkgeval-worker`).

**Cost tracking**: the provider stamps every resource `Project = pkgeval,
Component = control-plane`; the EC2 worker fleet (instances and their gp3
volumes, via launch-template tag specs and ASG-propagated tags) overrides
`Component = workers`. Activate both under Billing → Cost allocation tags
(one-time, console-only; categorizes usage from activation onward), then split
the two pools in Cost Explorer — optionally as Cost Categories, with an AWS
Budget alert on the workers pool.

**Fleet generations**: every instance of one scale-out runs identical code.
The first instance of a generation samples the last CI-green sha (the deploy
job writes it to SSM `/pkgeval/worker-ref` only after all bundles *and* that
commit's sysimage are published) and records it in the runs table under the
`_fleet-generation` sentinel with a conditional write; later instances —
including mid-run spot replacements — join the recorded ref. Workers heartbeat
the record while alive, so a generation ends only when the fleet scales to
zero: deploys take effect at the next scale-from-zero, never mid-run, and code
skew within a fleet is impossible by construction. Protocol changes should
still stay one-version compatible (messages/queues/schemas), since separate
farm components (Lambdas, enrolled workers) deploy independently.

**Gradual scale-down**: instances launch with scale-in protection and each
worker manages its own — dropping it once drained, restoring it on the next
claim — so the idle policy fires on empty *queues* alone and only ever reaps
machines with nothing running. Near the end of a run, when the visible backlog
falls below the fleet's spare capacity, the newest instances additionally stop
claiming (an instance drains iff backlog < the summed slots of instances ranked
ahead of it — size-aware, and the oldest, with the warmest caches, never
drains), consolidating the tail onto fewer machines. All
best-effort: any API failure leaves an instance busy-and-protected, which is
the pre-feature behavior.

**Two-tier job scheduling**: at expansion, jobs above a duration cutoff go to
`<prefix>-jobs-slow`, which workers drain before the main queue. The cutoff is
derived from the run's own duration mix (estimates from recent completed runs;
unknown packages classed slow): the smallest value such that the fast class
still holds enough aggregate work to backfill behind the longest job. The
cutoff bounds the end-of-run straggler tail. Queue *priority* is used because
SQS standard-queue delivery under backlog is nowhere near FIFO (empirically
roughly recency-biased), so enqueue order carries no information. Scaling
policies sum both queues.

**Sysimage bootstrap**: bringing the depot up from cold costs 137s, of which
~75s is precompiling AWS.jl, PkgEval and their dependency trees, and EC2
workers launch constantly (spot replacement, queue-driven scale-out,
scale-to-zero). CI therefore publishes a
sysimage per (commit, Julia version) to `s3://<bucket>-lambda/sysimage/<sha>/`,
which cloud-init downloads with the instance profile (read-only, that prefix
only) and passes to julia as `-J` — 62s to fetch packages and artifacts, plus
the image download, and the worker loads in under a second. Keyed by commit, so the image always matches
the checked-out code, and create-only, since workers execute it. Every failure
path — no image for that commit, a Julia patch bump CI has not built for, a bad
download — falls back to plain `Pkg.instantiate`, so a missing sysimage costs
time, never a dead worker. Manually enrolled workers do not get this grant:
they are long-lived, so they precompile once and never care.

**Container prerequisites**: PkgEval drives rootless containers with `crun
--systemd-cgroup`, which needs the worker user's own systemd manager and
session D-Bus — a plain `User=` system service has neither, so cloud-init
enables lingering for the worker. It also delegates `cpuset` to user managers
(systemd's default omits it), which the per-slot CPU pinning requires;
without it containers fail with "the requested cgroup controller `cpuset` is
not available", which PkgEval reports only as `skip`/`uninstallable`.

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
| `region` | no | `"us-east-2"` | AWS region to deploy into. |
| `broker_domain` | no | `"pkgeval.julialang.org"` | CloudFront-fronted CNAME for the broker; `""` disables. |
| `bucket_name` | no | `"pkgeval"` | S3 bucket for PkgEval results (and, suffixed `-lambda`, deploy bundles). |
| `github_org` | **yes** | — | GitHub organization whose teams gate access. |
| `worker_team` | no | `"pkgeval-workers"` | Team slug allowed to run workers. |
| `submitter_team` | no | `"pkgeval-submitters"` | Team slug allowed to submit runs. |
| `github_client_id` | **yes** | — | Client ID of the public GitHub OAuth app used for the device flow. |
| `cred_duration_seconds` | no | `3600` | Lifetime of the temporary credentials the broker vends. |
| `public_reports` | no | `true` | Make `runs/*/report/*` and `runs/*/logs/*` publicly readable. |
| `github_bot_token` | no | `""` | Token of the bot's GitHub account; empty disables the bot Lambda. |
| `bot_submitter_team` | no | `null` | Team gating bot commands (null = `submitter_team`; `""` = any org member). |
| `github_webhook_secret` | no | `""` | Secret for GitHub webhook verification; empty disables the webhook endpoint. |
| `bot_name` | no | `"pkgeval"` | GitHub handle the bot answers to. |
| `bot_schedule` | no | `"rate(1 hour)"` | EventBridge schedule for fallback bot polls. |
| `ec2_worker_max` | no | `0` | EC2 worker ceiling in job slots = vCPUs (0 = disabled; validated ≤ 384 for now). |
| `ec2_worker_min` | no | `0` | EC2 worker floor in slots (= max to pin capacity). |
| `ec2_worker_backlog_target` | no | `12.5` | Visible jobs per slot (vCPU) the scaler aims for. |
| `ec2_worker_idle_minutes` | no | `15` | Full queue idle time before scaling to the floor. |
| `ec2_worker_instance_types` | no | eleven M types, 8–24xlarge | Spot pools; sizes mix freely (vCPU-weighted, allocator picks by price/slot). |
| `ec2_worker_on_demand_percent` | no | `0` | Share of capacity on-demand instead of spot. |
| `ec2_worker_disk_gb` | no | `200` | Worker root volume (GB). |
| `ec2_worker_farm_repo` / `_ref` | no | JuliaCI repo, `master` | Where EC2 workers clone PkgEvalFarm.jl from. |
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

3. Create the two DNS records from the `broker_dns_records` output in the
   broker domain's zone (julialang.org lives at Namecheap, outside terraform;
   see broker_domain.tf for the two-step bring-up — the ACM validation record
   is needed *during* the first apply). Once the name resolves, workers and
   submitters need no configuration at all; the raw `broker_function_url`
   output keeps working as a fallback.

Re-run steps 1–2 whenever the broker code changes; the `source_code_hash`
picks up the new zip automatically.

**Changing regions**: never flip `region` against existing state — refresh
would look in the new region, find nothing, and plan a full re-create while
orphaning the still-running old stack. `tofu destroy` with the *old* region
first, then change the variable and apply fresh. Rename the buckets in the
same move (S3's global namespace releases deleted names only after an
unbounded delay), and carry the out-of-band SSM secrets over — they are not
in terraform. `bin/farm-secrets` does that (backup *before* the destroy,
restore *after* the apply — the placeholders must exist first):

```sh
bin/farm-secrets backup --region <old> -o secrets.json   # before destroy
bin/farm-secrets restore --region <new> -i secrets.json  # after apply
```

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

## Requesting builds from CI

PkgEval fetches Julia binaries that CI has already staged, so workers normally
never compile anything. When a commit has no staged artifact — a closed PR, an
expired ephemeral artifact, a commit CI never built — the farm asks the
`julia-build-request` pipeline to build it.

Workers must be able to trigger that, but must not hold the credential that
does: they run arbitrary package code. So the Buildkite token lives in an SSM
parameter (`buildkite_token_parameter`) that only `${prefix}-build-request` can
read, and workers reach that Lambda through a Function URL with `AWS_IAM`
authorization — SigV4 with the credentials they already have. Authorization is
two-sided: the worker roles hold `lambda:InvokeFunctionUrl`, and the function's
resource policy names those roles as the only permitted callers.

The Lambda validates before acting (repo must be `JuliaLang/julia`, a 40-hex
sha, variant `linux` or `linuxassert`; the org and pipeline come from its own
environment, never the caller) and deduplicates on `<sha>/<variant>` so a
commit is built once however many workers ask.

Repeat asks double as failure detection: while the artifact is missing,
workers re-ask every ~10 minutes, and each ask polls the triggered build's
state. A failed/canceled build flips the claim to `failed` and answers
`build-failed` (with the build URL), which workers surface as a run failure or
job error instead of waiting for an artifact that will never come. Claims
without an artifact after 3 h fail on age alone; failed claims may be
re-triggered by a fresh ask after 24 h, so a transient Buildkite failure does
not poison the sha forever (delete the claim item to retry sooner).

The token belongs to a Buildkite **machine user** whose team access covers the
build-request pipeline and nothing else — scope names are organization-wide, so
team membership is the real boundary. It needs `write_builds` (to create the
build) and `read_builds` (so a failed build is distinguishable from a slow one).

Terraform creates the parameter with a placeholder and never manages its value;
set it out of band so no token enters state:

```sh
printf '%s' 'bkua_...' > /tmp/bk-token
aws ssm put-parameter --name /pkgeval/buildkite-token \
  --type SecureString --value file:///tmp/bk-token --overwrite
shred -u /tmp/bk-token
```

Set `buildkite_pipeline = ""` to remove the whole mechanism.

## Debug access

`${prefix}-debug` is a narrowly scoped role for handing someone short-lived
credentials to diagnose a problem. It is created by default
(`debug_role_enabled`) and grants nothing until assumed.

**AWS forbids the account root user from assuming any role.** If root is your
only identity, `debug_user_enabled` (default true) also creates a
`${prefix}-debug` IAM *user* whose sole permission is assuming that role.
Create its access key out of band — deliberately not in terraform state — and
keep it only as long as you need it:

```sh
aws iam create-access-key --user-name pkgeval-debug     # as root, once
# ...later:
aws iam delete-access-key --user-name pkgeval-debug --access-key-id AKIA...
```

Then, with that user's credentials (e.g. as an `AWS_PROFILE`):

```sh
aws sts assume-role \
  --role-arn "$(tofu output -raw debug_role_arn)" \
  --role-session-name debug --duration-seconds 3600 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text
```

Export the three values as `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_SESSION_TOKEN` (or write them to `~/.aws/credentials`). They expire after
`debug_role_max_session_seconds` (default 1 hour) and cannot be renewed by the
holder.

The role grants:

- **SSM shell on farm workers only** — `ssm:SendCommand`/`StartSession`
  conditioned on the instance tag `Name = ${prefix}-ec2-worker`, so no other
  instance in the account is reachable;
- **read-only** on the jobs queue and its DLQ, both DynamoDB tables, the
  results bucket, the farm's Lambda log groups and function configuration;
- **nothing mutating** — no scaling, no writes, no IAM, no terraform.

Two caveats worth stating plainly. Shell on a worker is effectively root on
that box: it can inspect and disturb running jobs, though the box itself holds
only worker-scoped credentials behind a bearer-gated proxy with IMDS
firewalled. And the `Describe*`/`List*` actions are unavoidably `Resource: "*"`
because AWS supports no resource-level permissions for them.

`debug_role_principals` is the trust policy's principal list — who is allowed
to assume the role. It defaults to the **account-root ARN**, which in IAM means
"delegate to this account": not the root user, but any principal in the account
that *also* holds `sts:AssumeRole` permission for this role. Set it to specific
user or role ARNs to narrow who can mint these credentials, or set
`debug_role_enabled = false` to remove the role entirely.

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

| Claim | Condition | Why |
| ----- | --------- | --- |
| `sub` | `∈ github_deploy_subjects` | **required** (see below); this org's immutable format pins owner id, repo id and branch |
| `aud` | `= sts.amazonaws.com` | a token minted for another audience can't be replayed here |
| `repository_id` | `= github_repository_id` | immutable: survives renames, path can't be re-claimed after deletion |
| `ref` | `= github_deploy_ref` | only the deploy branch |
| `job_workflow_ref` | `= github_deploy_workflow_ref` | only *this* workflow file; a new workflow on the branch doesn't inherit the grant |

Two IAM rules constrain what may go here. Violating either produces the same
opaque `Not authorized to perform sts:AssumeRoleWithWebIdentity`, with no hint
as to which condition failed:

1. **`sub` must be evaluated.** GitHub Actions is a *shared* OIDC provider
   (many AWS customers trust the same issuer), so IAM demands an
   [identity-provider control](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc_secure-by-default.html):
   `token.actions.githubusercontent.com:sub`, not a bare wildcard. A policy that
   pins only the GitHub-specific claims and drops `sub` is unassumable —
   the docs say such an update should fail with `MalformedPolicyDocument`, but
   in practice terraform applied it happily and only STS refused later.
2. **Only mapped claims work.** `actor`, `actor_id`, `job_workflow_ref`,
   `repository`, `repository_id`, `repository_owner_id`, `workflow`, `ref`,
   `environment`, `enterprise_id`, plus `aud`/`sub`/`amr`
   ([docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#condition-keys-wif)).
   Conditions on `event_name`, `runner_environment`, `repository_owner` or
   `workflow_ref` can never match.

Note the subject format is org-configurable: this org mints the *immutable*
variant, `repo:OWNER@<owner_id>/REPO@<repo_id>:ref:refs/heads/master`, not the
documented `repo:OWNER/REPO:...`. Dump a real token before writing the policy:

```yaml
- run: |
    tok=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
    echo "$tok" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
```

Forks and pull requests are excluded by `ref` and by `sub`'s trailing
`:ref:refs/heads/master` (a PR run carries `refs/pull/N/merge`). GitHub also
caps fork-PR permissions at read-only, so such a job cannot mint a token at
all. Guards IAM cannot express — only on `push`, only on a GitHub-hosted runner
— live in the deploy job's `if:` and should be backed by branch protection.

To validate a trust-policy change without waiting for the full pipeline, add a
throwaway job to the workflow that assumes the role and runs
`aws sts get-caller-identity` (it must live in ci.yml itself so its
`job_workflow_ref` matches the deploy job's); the publish job exercises the
trust policy for real on every master push.

Terraform bootstraps the initial bundles and then defers to CI: the zip objects
and the functions' `source_code_hash` carry `ignore_changes`, so a later
`tofu apply` from a stale checkout will not roll back a CI-published bundle.
