output "api_base_url" {
  description = "API Gateway stage URL (POST /steps, GET /steps/summary)."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "summary_url" {
  description = "Cached summary endpoint used by the benchmark."
  value       = "${aws_api_gateway_stage.this.invoke_url}/steps/summary"
}

output "kinesis_stream_name" {
  description = "Kinesis Data Stream name."
  value       = aws_kinesis_stream.watch_steps.name
}

output "redshift_target" {
  description = "Redshift Serverless workgroup or provisioned cluster identifier."
  value       = coalesce(local.redshift_data_target.workgroup_name, local.redshift_data_target.cluster_identifier)
}

output "redshift_endpoint" {
  description = "Redshift endpoint (private; use the Data API / Query Editor v2)."
  value = (
    local.serverless
    ? aws_redshiftserverless_workgroup.this[0].endpoint[0].address
    : aws_redshift_cluster.this[0].endpoint
  )
}

output "lambda_function_names" {
  description = "Lambda functions (processor, ingest, query)."
  value = {
    processor = aws_lambda_function.processor.function_name
    ingest    = aws_lambda_function.ingest.function_name
    query     = aws_lambda_function.query.function_name
  }
}

output "grafana_url" {
  description = "Grafana UI (Managed Grafana workspace, or EC2 ~3-5 minutes after apply)."
  value = (
    local.managed_grafana
    ? "https://${aws_grafana_workspace.this[0].endpoint}"
    : "http://${aws_instance.grafana[0].public_ip}:3000"
  )
}
