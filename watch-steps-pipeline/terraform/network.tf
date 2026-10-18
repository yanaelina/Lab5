# Default VPC, used by Redshift Serverless and the optional Grafana EC2 instance.
# Restricted to subnets in AZs that offer the Grafana instance type
# (e.g. us-east-1e does not offer t3.*).
data "aws_vpc" "default" {
  default = true
}

data "aws_ec2_instance_type_offerings" "grafana" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.grafana_instance_type]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.grafana.locations
  }
}
