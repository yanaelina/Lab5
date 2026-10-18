# Credentials come ONLY from the named AWS CLI profile (AWS Academy Learner Lab).
# No access keys, secret keys or session tokens are ever written in this project.
provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Same account/region without default_tags, for services whose tagging API
# AWS Academy denies (grafana:TagResource).
provider "aws" {
  alias   = "untagged"
  profile = var.aws_profile
  region  = var.aws_region
}

# Talks to the Amazon Managed Grafana workspace with a Terraform-created
# service account token. With grafana_mode = "ec2" no grafana_* resources
# exist, so the placeholder values are never used.
provider "grafana" {
  url  = try("https://${aws_grafana_workspace.this[0].endpoint}", "http://localhost:3000")
  auth = try(aws_grafana_workspace_service_account_token.terraform[0].key, "unused")
}

locals {
  project = "watch-steps-pipeline"

  common_tags = {
    Project = local.project
  }
}
