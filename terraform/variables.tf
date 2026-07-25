variable "name_prefix" {
  description = "Prefix used for naming all PkgEvalFarm resources."
  type        = string
  default     = "pkgeval"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the S3 bucket that stores PkgEval results (reports, logs, artifacts)."
  type        = string
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
  description = "Client ID of the (public) GitHub OAuth app used for the device flow."
  type        = string
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

variable "github_bot_token" {
  description = "GitHub token of the @nanosoldier2 bot account. Empty disables the bot Lambda."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bot_name" {
  description = "GitHub handle the bot answers to (without @)."
  type        = string
  default     = "nanosoldier2"
}

variable "bot_schedule" {
  description = "EventBridge schedule for fallback bot polls (webhook + stream are the primary triggers)."
  type        = string
  default     = "rate(1 hour)"
}

variable "github_webhook_secret" {
  description = "Secret for verifying GitHub issue_comment webhooks. Empty disables the webhook endpoint (the bot then relies on the scheduled poll)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "test_worker_count" {
  description = "Number of self-enrolling EC2 test workers (0 disables everything test-worker related)."
  type        = number
  default     = 0
}

variable "test_worker_instance_type" {
  description = "Instance type for test workers."
  type        = string
  default     = "c6i.2xlarge"
}

variable "test_worker_disk_gb" {
  description = "Root volume size for test workers (rootfs/compile caches are hungry)."
  type        = number
  default     = 200
}

variable "test_worker_farm_repo" {
  description = "Git URL the test workers clone PkgEvalFarm.jl from."
  type        = string
  default     = "https://github.com/KenoAIStaging/PkgEvalFarm.jl"
}

variable "test_worker_farm_ref" {
  description = "Branch/tag of PkgEvalFarm.jl to check out on test workers."
  type        = string
  default     = "master"
}

variable "test_worker_julia_channel" {
  description = "juliaup channel installed on test workers."
  type        = string
  default     = "1.12"
}
