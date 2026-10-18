# Visualization. grafana_mode selects where Grafana runs:
#   "managed" (default) - Amazon Managed Grafana workspace, configured with the
#                         grafana provider (data sources + dashboards).
#   "ec2"               - fallback for accounts without IAM Identity Center
#                         (e.g. AWS Academy): Grafana OSS on EC2 via user_data.
locals {
  managed_grafana = var.grafana_mode == "managed"
  ec2_grafana     = var.grafana_mode == "ec2"

  dashboard_files = {
    "watch-steps.json" = file("${path.module}/../grafana/dashboards/watch-steps.json")
    "api-gateway.json" = templatefile("${path.module}/../grafana/dashboards/api-gateway.json.tftpl", {
      api_name = aws_api_gateway_rest_api.this.name
      stage    = aws_api_gateway_stage.this.stage_name
    })
  }
}

# ---------------------------------------------------------------------------
# Amazon Managed Grafana
# ---------------------------------------------------------------------------
resource "aws_grafana_workspace" "this" {
  count = local.managed_grafana ? 1 : 0

  # No default_tags: AWS Academy denies grafana:TagResource.
  provider = aws.untagged

  name                     = var.grafana_workspace_name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = var.grafana_authentication_providers
  # CUSTOMER_MANAGED + an existing role: no IAM resources are created.
  permission_type = "CUSTOMER_MANAGED"
  role_arn        = data.aws_iam_role.lab_role.arn
  data_sources    = ["REDSHIFT", "CLOUDWATCH"]
  grafana_version = var.grafana_version
}

resource "aws_grafana_role_association" "admins" {
  count = local.managed_grafana && length(var.grafana_admin_user_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.this[0].id
  role         = "ADMIN"
  user_ids     = var.grafana_admin_user_ids
}

# Service account + token used by the grafana provider below.
resource "aws_grafana_workspace_service_account" "terraform" {
  count = local.managed_grafana ? 1 : 0

  workspace_id = aws_grafana_workspace.this[0].id
  name         = "terraform"
  grafana_role = "ADMIN"
}

resource "aws_grafana_workspace_service_account_token" "terraform" {
  count = local.managed_grafana ? 1 : 0

  workspace_id       = aws_grafana_workspace.this[0].id
  service_account_id = aws_grafana_workspace_service_account.terraform[0].service_account_id
  name               = "terraform"
  seconds_to_live    = 2592000 # 30 days (maximum)
}

resource "grafana_data_source" "redshift" {
  count = local.managed_grafana ? 1 : 0

  type       = "grafana-redshift-datasource"
  name       = "Amazon Redshift"
  uid        = "redshift-watch-steps"
  is_default = true

  json_data_encoded = jsonencode({ for k, v in {
    authType          = "ec2_iam_role" # = "Workspace IAM role" in Managed Grafana
    defaultRegion     = var.aws_region
    useServerless     = local.serverless
    workgroupName     = local.redshift_data_target.workgroup_name
    clusterIdentifier = local.redshift_data_target.cluster_identifier
    dbUser            = local.redshift_data_target.db_user
    database          = var.redshift_database
  } : k => v if v != null })
}

resource "grafana_data_source" "cloudwatch" {
  count = local.managed_grafana ? 1 : 0

  type = "cloudwatch"
  name = "CloudWatch"
  uid  = "cloudwatch-watch-steps"

  json_data_encoded = jsonencode({
    authType      = "ec2_iam_role"
    defaultRegion = var.aws_region
  })
}

resource "grafana_folder" "watch_steps" {
  count = local.managed_grafana ? 1 : 0

  title = "Apple Watch"
}

resource "grafana_dashboard" "this" {
  for_each = local.managed_grafana ? local.dashboard_files : {}

  folder      = grafana_folder.watch_steps[0].uid
  config_json = each.value
  overwrite   = true

  depends_on = [grafana_data_source.redshift, grafana_data_source.cloudwatch]
}

# ---------------------------------------------------------------------------
# Fallback: Grafana OSS on EC2
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
  count = local.ec2_grafana ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "grafana" {
  count = local.ec2_grafana ? 1 : 0

  name        = "watch-steps-grafana-sg"
  description = "Grafana UI (3000/tcp) from allowed_cidr only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "grafana_ui" {
  count = local.ec2_grafana ? 1 : 0

  security_group_id = aws_security_group.grafana[0].id
  description       = "Grafana UI"
  cidr_ipv4         = var.allowed_cidr
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  count = local.ec2_grafana ? 1 : 0

  security_group_id = aws_security_group.grafana[0].id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

locals {
  grafana_datasource_yaml = templatefile("${path.module}/../grafana/provisioning/datasources/redshift.yaml.tftpl", {
    region             = var.aws_region
    serverless         = local.serverless
    workgroup          = local.redshift_data_target.workgroup_name
    cluster_identifier = local.redshift_data_target.cluster_identifier
    db_user            = local.redshift_data_target.db_user
    database           = var.redshift_database
  })

  grafana_user_data = templatefile("${path.module}/templates/grafana_user_data.sh.tftpl", {
    datasource_yaml    = local.grafana_datasource_yaml
    dashboard_provider = file("${path.module}/../grafana/provisioning/dashboards/dashboards.yaml")
    dashboard_files    = local.dashboard_files
  })
}

resource "aws_instance" "grafana" {
  count = local.ec2_grafana ? 1 : 0

  ami                         = data.aws_ami.al2023[0].id
  instance_type               = var.grafana_instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.grafana[0].id]
  iam_instance_profile        = var.lab_instance_profile_name
  associate_public_ip_address = true

  user_data                   = local.grafana_user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "watch-steps-grafana"
  }
}
