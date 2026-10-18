# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
variable "aws_profile" {
  description = "AWS CLI profile used for credentials (AWS Academy Learner Lab)."
  type        = string
  default     = "academy"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# AWS Academy pre-existing IAM (we cannot create IAM resources)
# ---------------------------------------------------------------------------
variable "lab_role_name" {
  description = "Existing IAM role used as the Lambda execution role."
  type        = string
  default     = "LabRole"
}

variable "lab_instance_profile_name" {
  description = "Existing instance profile attached to the Grafana EC2 instance."
  type        = string
  default     = "LabInstanceProfile"
}

# ---------------------------------------------------------------------------
# Kinesis
# ---------------------------------------------------------------------------
variable "stream_name" {
  description = "Kinesis Data Stream name."
  type        = string
  default     = "watch-steps-stream"
}

# ---------------------------------------------------------------------------
# Redshift
# ---------------------------------------------------------------------------
variable "redshift_mode" {
  description = "\"serverless\" = Redshift Serverless; \"provisioned\" = single-node cluster (fallback when redshift-serverless:* is denied, e.g. AWS Academy)."
  type        = string
  default     = "serverless"

  validation {
    condition     = contains(["serverless", "provisioned"], var.redshift_mode)
    error_message = "redshift_mode must be \"serverless\" or \"provisioned\"."
  }
}

variable "redshift_namespace_name" {
  description = "redshift_mode = \"serverless\" only: namespace name."
  type        = string
  default     = "watch-steps-ns"
}

variable "redshift_workgroup_name" {
  description = "redshift_mode = \"serverless\" only: workgroup name."
  type        = string
  default     = "watch-steps-wg"
}

variable "redshift_base_capacity" {
  description = "redshift_mode = \"serverless\" only: base capacity in RPUs (minimum 8; billed only while queries run)."
  type        = number
  default     = 8
}

variable "redshift_cluster_identifier" {
  description = "redshift_mode = \"provisioned\" only: cluster identifier."
  type        = string
  default     = "watch-steps-cluster"
}

variable "redshift_node_type" {
  description = "redshift_mode = \"provisioned\" only: node type. dc2.large can no longer be launched; ra3.large is the cheapest allowed type."
  type        = string
  default     = "ra3.large"
}

variable "redshift_database" {
  description = "Database created in Redshift."
  type        = string
  default     = "stepsdb"
}

variable "redshift_admin_username" {
  description = "Redshift admin username."
  type        = string
  default     = "awsuser"
}

variable "redshift_admin_password" {
  description = "Redshift admin password. Supply via terraform.tfvars (never commit it)."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.redshift_admin_password) >= 8 &&
      length(var.redshift_admin_password) <= 64 &&
      can(regex("[A-Z]", var.redshift_admin_password)) &&
      can(regex("[a-z]", var.redshift_admin_password)) &&
      can(regex("[0-9]", var.redshift_admin_password)) &&
      !can(regex("[/@\"' \\\\]", var.redshift_admin_password))
    )
    error_message = "Password must be 8-64 chars with upper, lower and a digit, and must not contain /, @, \", ', space or backslash."
  }
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------
variable "lambda_function_name" {
  description = "Stream processor Lambda function name."
  type        = string
  default     = "watch-steps-processor"
}

variable "ingest_function_name" {
  description = "Lambda behind POST /steps (writes to Kinesis)."
  type        = string
  default     = "watch-steps-ingest"
}

variable "query_function_name" {
  description = "Lambda behind GET /steps/summary (reads Redshift)."
  type        = string
  default     = "watch-steps-query"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------
variable "api_name" {
  description = "REST API name."
  type        = string
  default     = "watch-steps-api"
}

variable "api_stage_name" {
  description = "API Gateway stage name."
  type        = string
  default     = "prod"
}

variable "api_cache_size" {
  description = "Stage cache cluster size in GB (0.5 is the smallest)."
  type        = string
  default     = "0.5"
}

variable "api_cache_ttl_seconds" {
  description = "TTL for cached GET /steps/summary responses (0-3600)."
  type        = number
  default     = 300
}

variable "api_throttle_rate_limit" {
  description = "Steady-state requests per second allowed per method."
  type        = number
  default     = 1000
}

variable "api_throttle_burst_limit" {
  description = "Burst of concurrent requests allowed per method."
  type        = number
  default     = 500
}

# ---------------------------------------------------------------------------
# Grafana
# ---------------------------------------------------------------------------
variable "grafana_mode" {
  description = "\"managed\" = Amazon Managed Grafana workspace; \"ec2\" = Grafana OSS on EC2 (fallback when IAM Identity Center is not available, e.g. AWS Academy)."
  type        = string
  default     = "managed"

  validation {
    condition     = contains(["managed", "ec2"], var.grafana_mode)
    error_message = "grafana_mode must be \"managed\" or \"ec2\"."
  }
}

variable "grafana_workspace_name" {
  description = "Amazon Managed Grafana workspace name."
  type        = string
  default     = "watch-steps-grafana"
}

variable "grafana_version" {
  description = "Amazon Managed Grafana version."
  type        = string
  default     = "10.4"
}

variable "grafana_authentication_providers" {
  description = "Managed Grafana sign-in: AWS_SSO (IAM Identity Center) and/or SAML."
  type        = list(string)
  default     = ["AWS_SSO"]
}

variable "grafana_admin_user_ids" {
  description = "IAM Identity Center user IDs that get the Grafana ADMIN role (optional)."
  type        = list(string)
  default     = []
}

variable "grafana_instance_type" {
  description = "grafana_mode = \"ec2\" only: EC2 instance type for Grafana."
  type        = string
  default     = "t3.micro"
}

variable "allowed_cidr" {
  description = "grafana_mode = \"ec2\" only: CIDR allowed to reach Grafana on port 3000, e.g. \"203.0.113.10/32\"."
  type        = string
  default     = "127.0.0.1/32"

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be a valid IPv4 CIDR, e.g. 203.0.113.10/32."
  }
}
