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
