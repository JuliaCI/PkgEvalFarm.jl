# Deployment-specific values (nothing here is secret; the bot's GitHub token
# and webhook secret live in SSM parameters, set out of band — see bot.tf).
#
# Access policy: any JuliaLang org member may submit runs and @pkgeval commands
# (submitter_team = "" means plain github_org membership, the classic
# Nanosoldier policy); enrolling workers is gated on the JuliaCI/pkgeval-workers
# team. The @pkgeval bot account must be a member of both orgs — it checks
# JuliaLang membership on behalf of command authors.
github_org     = "JuliaLang"
submitter_team = ""
worker_team    = "JuliaCI/pkgeval-workers"

# this account already has a GitHub Actions OIDC provider (AWS allows only one
# per issuer URL), so reference it instead of creating a second one
github_oidc_provider_arn = "arn:aws:iam::873569884612:oidc-provider/token.actions.githubusercontent.com"

# EC2 worker fleet. These live here rather than on the command line: a value
# passed with -var reverts to its default on the next apply, which would tear
# the auto-scaling group down. min=0 keeps scale-to-zero, so the ceiling costs
# nothing while the queue is empty. Capacity is in job slots (= vCPUs), not
# instances: 384 ≈ twelve 8xlarge or four 24xlarge, however the allocator
# slices it.
ec2_worker_max     = 384
ec2_worker_min     = 0
ec2_worker_disk_gb = 400

# The @pkgeval bot. Its GitHub token and webhook secret go into SSM after the
# first apply (see the put-parameter commands in bot.tf).
enable_bot = true

# 12 h debug-role sessions: long enough for an overnight farm watch without
# hourly re-minting. Drop back toward the 3600 default when that stops being
# routine — these credentials get handed to a third party (the debug agent).
debug_role_max_session_seconds = 43200
