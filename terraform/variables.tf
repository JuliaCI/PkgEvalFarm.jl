variable "name_prefix" {
  description = "Prefix used for naming all PkgEvalFarm resources."
  type        = string
  default     = "pkgeval"
}

variable "region" {
  description = "AWS region to deploy into. us-east-2: spot capacity for our instance class runs 25-30% cheaper than us-east-1 (serverless pricing is identical); the julia build staging buckets stay in us-east-1, but cross-region build downloads cost pennies."
  type        = string
  default     = "us-east-2"
}

variable "broker_domain" {
  description = "Custom domain fronting the broker via CloudFront (see broker_domain.tf). Empty string disables; DNS records for the zone are emitted as the broker_dns_records output."
  type        = string
  default     = "pkgeval.julialang.org"
}

variable "bucket_name" {
  description = "Name of the S3 bucket that stores PkgEval results (reports, logs, artifacts). Also prefixes the Lambda deploy bucket (\"<name>-lambda\")."
  type        = string
  default     = "pkgeval"
}

variable "github_org" {
  description = "GitHub organization whose team membership gates access to the farm."
  type        = string
}

variable "worker_team" {
  description = "GitHub team slug whose members may enroll machines as PkgEval workers."
  type        = string
  default     = "pkgeval-workers"
}

variable "submitter_team" {
  description = "GitHub team slug whose members may submit PkgEval runs."
  type        = string
  default     = "pkgeval-submitters"
}

variable "github_client_id" {
  description = "Client ID of the (public) GitHub OAuth app used for the device flow. Not a secret."
  type        = string
  default     = "Ov23lizNGZDa3XiWu3jh"
}

variable "cred_duration_seconds" {
  description = "Duration (in seconds) of the temporary AWS credentials the broker vends."
  type        = number
  default     = 3600
}

variable "public_reports" {
  description = "If true, PkgEval reports and logs in the results bucket are publicly readable."
  type        = bool
  default     = true
}

variable "enable_bot" {
  description = "Create the bot Lambda. Its GitHub token and webhook secret are read from the SSM parameters below, set out of band."
  type        = bool
  default     = false
}

variable "bot_token_parameter" {
  description = "SSM parameter holding the bot account's GitHub token."
  type        = string
  default     = "/pkgeval/bot-github-token"
}

variable "bot_webhook_secret_parameter" {
  description = "SSM parameter holding the GitHub webhook secret. While it still holds the placeholder, every webhook delivery is rejected (401) and the bot relies on the scheduled poll."
  type        = string
  default     = "/pkgeval/bot-webhook-secret"
}

variable "bot_name" {
  description = "GitHub handle the bot answers to (without @)."
  type        = string
  default     = "pkgeval"
}

variable "bot_schedule" {
  description = "EventBridge schedule for fallback bot polls (webhook + stream are the primary triggers)."
  type        = string
  default     = "rate(1 hour)"
}

variable "ec2_worker_max" {
  description = "Capacity ceiling for EC2 workers (0 disables everything EC2-worker related). Scaling within [min, max] is queue-driven."
  type        = number
  default     = 0

  # deliberate guardrail while the farm is young: raise this limit here when
  # you actually mean to run a bigger fleet
  validation {
    condition     = var.ec2_worker_max <= 4
    error_message = "ec2_worker_max is capped at 4 for now (worst case ≈ $2.5/h spot); raise the cap in variables.tf deliberately if you need more."
  }
}

variable "ec2_worker_min" {
  description = "Capacity floor for EC2 workers. Set equal to ec2_worker_max to pin fixed capacity."
  type        = number
  default     = 0
}

variable "ec2_worker_backlog_target" {
  description = "Target visible queue backlog per in-service worker; lower = more aggressive scale-out. 400 clears a full backlog share in roughly half an hour on a 32-vCPU worker."
  type        = number
  default     = 400
}

variable "ec2_worker_idle_minutes" {
  description = "How long the queue must be fully idle (nothing visible or in flight) before scaling down to the floor."
  type        = number
  default     = 15
}

variable "ec2_worker_instance_types" {
  description = "Instance types the spot fleet may use. 4 GB/vCPU recommended (heavy package tests); one machine amortizes Julia builds and caches across all its job slots, so prefer fewer, larger instances. Keep the list uniform in size (32 vCPU): the scheduler's slot math (PKGEVAL_FLEET_SLOTS, backlog-per-instance target) assumes identical instances. More entries = deeper spot pools for price-capacity-optimized to choose from; x86 only (the sysimage and result comparability assume it)."
  type        = list(string)
  default     = ["m6a.8xlarge", "m6i.8xlarge", "m5a.8xlarge", "m7a.8xlarge", "m7i.8xlarge", "m5.8xlarge"]
}

variable "ec2_worker_on_demand_percent" {
  description = "Percentage of capacity to run on-demand instead of spot (0 = all spot; interruptions are safe, jobs are simply redelivered)."
  type        = number
  default     = 0
}

variable "ec2_worker_disk_gb" {
  description = "Root volume size for EC2 workers (rootfs/compile caches are hungry)."
  type        = number
  default     = 200
}

variable "ec2_worker_farm_repo" {
  description = "Git URL the EC2 workers clone PkgEvalFarm.jl from."
  type        = string
  default     = "https://github.com/JuliaCI/PkgEvalFarm.jl"
}

variable "ec2_worker_farm_ref" {
  description = "Branch/tag of PkgEvalFarm.jl to check out on EC2 workers."
  type        = string
  default     = "master"
}

variable "ec2_worker_julia_channel" {
  description = "juliaup channel installed on EC2 workers."
  type        = string
  default     = "1.12"
}

variable "bot_submitter_team" {
  description = "Team gating @bot commands. null = same as submitter_team; empty string = any github_org member (classic Nanosoldier's documented policy)."
  type        = string
  default     = null
  nullable    = true
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub Actions OIDC provider ARN. null creates one (an account may only have a single provider per URL)."
  type        = string
  default     = null
  nullable    = true
}

variable "github_deploy_subjects" {
  description = "GitHub OIDC `sub` claims allowed to publish Lambda bundles. The exact format is org-dependent — dump a real token before changing it (README), since a mismatch denies with no explanation."
  type        = list(string)
  # Whether JuliaCI mints the immutable subject variant (embedding numeric
  # owner/repo ids) or the default one is org configuration we cannot read, so
  # both candidates are allowed — they are OR'd, each pins repo *and* branch,
  # and repository_id below pins the repo regardless of the sub format. Once a
  # real token has been dumped (README), prune to the observed value.
  default = [
    "repo:JuliaCI@9957604/PkgEvalFarm.jl@1311559445:ref:refs/heads/master",
    "repo:JuliaCI/PkgEvalFarm.jl:ref:refs/heads/master",
  ]
}

variable "github_repository_id" {
  description = "Numeric repository id, pinned via the repository_id claim (immutable across renames). null omits."
  type        = string
  # numeric ids survive repository transfers, so this held across the move
  # from the KenoAIStaging staging org
  default  = "1311559445" # JuliaCI/PkgEvalFarm.jl
  nullable = true
}

variable "github_repository_owner_id" {
  description = "Numeric owner id, pinned via the repository_owner_id claim. null omits. Off by default: repository_id already identifies the repo uniquely, and every condition should be a value observed in an actual token dump."
  type        = string
  default     = null
  nullable    = true
}

variable "github_deploy_ref" {
  description = "Git ref allowed to deploy, matched against the `ref` claim. null omits (the branch is also pinned inside `sub`)."
  type        = string
  default     = "refs/heads/master"
  nullable    = true
}

variable "github_deploy_workflow_ref" {
  description = "Workflow file allowed to deploy (OWNER/REPO/.github/workflows/FILE@REF), matched against `job_workflow_ref`. null omits."
  type        = string
  # works alongside `sub`, which IAM requires for GitHub (see cicd.tf)
  default  = "JuliaCI/PkgEvalFarm.jl/.github/workflows/ci.yml@refs/heads/master"
  nullable = true
}

variable "debug_role_enabled" {
  description = "Create the scoped debug role. It grants nothing until somebody assumes it, and assuming it requires sts:AssumeRole permission of your own."
  type        = bool
  default     = true
}

variable "debug_role_principals" {
  description = "ARNs allowed to assume the debug role. null means the account-root ARN, i.e. any principal in this account that separately holds sts:AssumeRole for it — not the root user. Narrow to specific user/role ARNs to restrict who can mint these credentials."
  type        = list(string)
  default     = null
  nullable    = true
}

variable "debug_role_max_session_seconds" {
  description = "Maximum session length for the debug role. Keep it short; credentials handed to a third party live only this long."
  type        = number
  default     = 3600
}

variable "debug_user_enabled" {
  description = "Create an IAM user whose only permission is assuming the debug role. Needed when the account's only identity is root, which AWS forbids from assuming roles. Its access key is created out of band, never in terraform state."
  type        = bool
  default     = true
}

variable "buildkite_org" {
  description = "Buildkite organization slug hosting the build-request pipeline."
  type        = string
  default     = "julialang"
}

variable "buildkite_pipeline" {
  description = "Pipeline slug the farm may trigger to build a commit CI has not staged (see the julia-buildkite PR adding it). Empty disables the build-request Lambda entirely."
  type        = string
  default     = "julia-build-request"
}

variable "buildkite_token_parameter" {
  description = "SSM parameter holding the Buildkite API token. Terraform creates it with a placeholder and never manages the value — set it with `aws ssm put-parameter --overwrite` so no token enters state. Use a machine user whose team access is limited to the build-request pipeline."
  type        = string
  default     = "/pkgeval/buildkite-token"
}
