# Deployment-specific values (nothing here is secret; bot/webhook tokens are
# passed at apply time or via TF_VAR_* environment variables).
github_org = "KenoAIStaging"

# this account already has a GitHub Actions OIDC provider (AWS allows only one
# per issuer URL), so reference it instead of creating a second one
github_oidc_provider_arn = "arn:aws:iam::873569884612:oidc-provider/token.actions.githubusercontent.com"
