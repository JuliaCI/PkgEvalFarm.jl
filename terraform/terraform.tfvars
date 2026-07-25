# Deployment-specific values (nothing here is secret; bot/webhook tokens are
# passed at apply time or via TF_VAR_* environment variables).
github_org = "KenoAIStaging"

# this account already has a GitHub Actions OIDC provider (AWS allows only one
# per issuer URL), so reference it instead of creating a second one
github_oidc_provider_arn = "arn:aws:iam::873569884612:oidc-provider/token.actions.githubusercontent.com"

# EC2 worker fleet. These live here rather than on the command line: a value
# passed with -var reverts to its default on the next apply, which would tear
# the auto-scaling group down. min=0 keeps scale-to-zero, so the ceiling costs
# nothing while the queue is empty.
ec2_worker_max     = 4
ec2_worker_min     = 0
ec2_worker_disk_gb = 400
