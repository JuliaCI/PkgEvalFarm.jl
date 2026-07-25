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
