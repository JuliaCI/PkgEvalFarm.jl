# Tags appear in Cost Explorer / the Cost and Usage Report only once
# activated as *cost-allocation* tags — an account-level billing setting,
# separate from the resources carrying them. Activation requires the key to
# have appeared on billable usage at least once (both have, since the first
# apply); billing data then shows the breakdown with up to ~24 h of lag.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "component" {
  tag_key = "Component"
  status  = "Active"
}

# The farm's costs as a custom billing view: pick "PkgEvalFarm" in Cost
# Explorer's billing view selector, then group by the Component tag or by
# service. It can be shared with other accounts through AWS RAM. It shows
# gross usage; the account's credits are not tagged, so they fall outside it.
# It misses the workers' public IPv4 charges, which AWS bills to the VPC
# untagged (a few dollars a month), and usage from before the tags were
# activated in late July 2026.
resource "aws_billing_view" "pkgeval" {
  provider     = aws.us_east_1 # billing is a global service served from us-east-1
  name         = "PkgEvalFarm"
  description  = "PkgEval farm costs - everything tagged Project=pkgeval" # no colons or commas allowed
  source_views = ["arn:aws:billing::${data.aws_caller_identity.current.account_id}:billingview/primary"]

  data_filter_expression {
    tags {
      key    = "Project"
      values = ["pkgeval"]
    }
  }
}

# The view was created with the CLI from a machine without this configuration's
# state (there is no remote backend), so adopt it rather than create a second
# one. Safe to delete once an apply has imported it.
import {
  to = aws_billing_view.pkgeval
  id = "arn:aws:billing::873569884612:billingview/custom-fde41164-7de5-4a39-a3b5-41187baf29cb"
}
