# redshift_mode selects the warehouse:
#   "serverless" (default) - Redshift Serverless namespace + workgroup.
#   "provisioned"          - single-node cluster; fallback for accounts that deny
#                            redshift-serverless:* (e.g. AWS Academy).
# Everything downstream talks to Redshift through the Data API, so only the
# target (WorkgroupName vs ClusterIdentifier + DbUser) changes.
locals {
  serverless = var.redshift_mode == "serverless"

  # Arguments shared by every aws_redshiftdata_statement.
  redshift_data_target = {
    workgroup_name     = local.serverless ? aws_redshiftserverless_workgroup.this[0].workgroup_name : null
    cluster_identifier = local.serverless ? null : aws_redshift_cluster.this[0].cluster_identifier
    db_user            = local.serverless ? null : var.redshift_admin_username
  }
}

# ---------------------------------------------------------------------------
# Redshift Serverless
# ---------------------------------------------------------------------------
resource "aws_redshiftserverless_namespace" "this" {
  count = local.serverless ? 1 : 0

  namespace_name      = var.redshift_namespace_name
  db_name             = var.redshift_database
  admin_username      = var.redshift_admin_username
  admin_user_password = var.redshift_admin_password
}

resource "aws_redshiftserverless_workgroup" "this" {
  count = local.serverless ? 1 : 0

  namespace_name = aws_redshiftserverless_namespace.this[0].namespace_name
  workgroup_name = var.redshift_workgroup_name
  base_capacity  = var.redshift_base_capacity # RPUs; billed per RPU-second only while queries run

  subnet_ids          = data.aws_subnets.default.ids
  publicly_accessible = false
}

# ---------------------------------------------------------------------------
# Provisioned cluster (fallback)
# ---------------------------------------------------------------------------
resource "aws_redshift_subnet_group" "this" {
  count = local.serverless ? 0 : 1

  name        = "${var.redshift_cluster_identifier}-subnets"
  description = "Default VPC subnets for ${var.redshift_cluster_identifier}"
  subnet_ids  = data.aws_subnets.default.ids
}

resource "aws_redshift_cluster" "this" {
  count = local.serverless ? 0 : 1

  cluster_identifier        = var.redshift_cluster_identifier
  cluster_type              = "single-node"
  node_type                 = var.redshift_node_type
  database_name             = var.redshift_database
  master_username           = var.redshift_admin_username
  master_password           = var.redshift_admin_password
  cluster_subnet_group_name = aws_redshift_subnet_group.this[0].name

  encrypted           = true
  publicly_accessible = false
  skip_final_snapshot = true

  # Lab cluster: keep automated snapshots minimal.
  automated_snapshot_retention_period = 1
}

# ---------------------------------------------------------------------------
# Schema, via the Redshift Data API (no JDBC, no VPC access)
# ---------------------------------------------------------------------------
# On Serverless every caller is mapped to a database user named after its IAM
# identity (e.g. IAMR:LabRole), so the objects are granted to PUBLIC so that
# Lambda, Grafana and Terraform can all use them.
resource "aws_redshiftdata_statement" "create_table" {
  workgroup_name     = local.redshift_data_target.workgroup_name
  cluster_identifier = local.redshift_data_target.cluster_identifier
  db_user            = local.redshift_data_target.db_user
  database           = var.redshift_database

  sql = <<-SQL
    CREATE TABLE IF NOT EXISTS public.watch_steps (
      device_id    VARCHAR(64)  NOT NULL,
      event_ts     TIMESTAMP    NOT NULL,
      steps        INTEGER      NOT NULL,
      ingested_at  TIMESTAMP    DEFAULT GETDATE()
    ) DISTKEY(device_id) SORTKEY(event_ts);
  SQL
}

resource "aws_redshiftdata_statement" "create_daily_view" {
  workgroup_name     = local.redshift_data_target.workgroup_name
  cluster_identifier = local.redshift_data_target.cluster_identifier
  db_user            = local.redshift_data_target.db_user
  database           = var.redshift_database

  sql = <<-SQL
    CREATE OR REPLACE VIEW public.v_daily_steps AS
    SELECT device_id,
           TRUNC(event_ts) AS day,
           SUM(steps)      AS total_steps
    FROM public.watch_steps
    GROUP BY device_id, TRUNC(event_ts);
  SQL

  depends_on = [aws_redshiftdata_statement.create_table]
}

resource "aws_redshiftdata_statement" "grants" {
  workgroup_name     = local.redshift_data_target.workgroup_name
  cluster_identifier = local.redshift_data_target.cluster_identifier
  db_user            = local.redshift_data_target.db_user
  database           = var.redshift_database

  sql = "GRANT SELECT, INSERT ON public.watch_steps TO PUBLIC; GRANT SELECT ON public.v_daily_steps TO PUBLIC;"

  depends_on = [aws_redshiftdata_statement.create_daily_view]
}
