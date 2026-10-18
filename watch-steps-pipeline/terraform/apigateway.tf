# REST API (v1): HTTP APIs (v2) have no response cache, REST APIs do.
#
#   POST /steps          -> ingest Lambda -> Kinesis        (never cached)
#   GET  /steps/summary  -> query Lambda  -> Redshift       (cached per ?device_id&nocache)
resource "aws_api_gateway_rest_api" "this" {
  name        = var.api_name
  description = "Apple Watch steps: ingestion and cached summary"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "steps" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "steps"
}

resource "aws_api_gateway_resource" "summary" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.steps.id
  path_part   = "summary"
}

# --- POST /steps -----------------------------------------------------------
resource "aws_api_gateway_method" "post_steps" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.steps.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_steps" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.steps.id
  http_method             = aws_api_gateway_method.post_steps.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.ingest.invoke_arn
}

# --- GET /steps/summary ----------------------------------------------------
resource "aws_api_gateway_method" "get_summary" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.summary.id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.querystring.device_id" = false
    "method.request.querystring.nocache"   = false
  }
}

resource "aws_api_gateway_integration" "get_summary" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.summary.id
  http_method             = aws_api_gateway_method.get_summary.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.query.invoke_arn

  # Each device_id value gets its own cache entry. nocache is ignored by the
  # Lambda; a fresh value is a never-loaded cache key, which is how the
  # benchmark measures the "cache not loaded" case.
  cache_key_parameters = [
    "method.request.querystring.device_id",
    "method.request.querystring.nocache",
  ]
}

# --- Permissions (resource-based; no IAM role needed) ----------------------
resource "aws_lambda_permission" "apigw_ingest" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/steps"
}

resource "aws_lambda_permission" "apigw_query" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/GET/steps/summary"
}

# --- Deployment + stage with cache ------------------------------------------
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.steps,
      aws_api_gateway_resource.summary,
      aws_api_gateway_method.post_steps,
      aws_api_gateway_method.get_summary,
      aws_api_gateway_integration.post_steps,
      aws_api_gateway_integration.get_summary,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.api_stage_name

  # Dedicated cache cluster for the stage (billed hourly while it exists).
  cache_cluster_enabled = true
  cache_cluster_size    = var.api_cache_size
}

# Defaults for every method: CloudWatch metrics + throttling.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    caching_enabled        = false
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }
}

# GET /steps/summary is served from the stage cache for api_cache_ttl_seconds.
resource "aws_api_gateway_method_settings" "summary_cache" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  # Slashes inside the resource path must be escaped as ~1 ("/steps/summary" ->
  # "steps~1summary"); unescaped, API Gateway stores a duplicate entry and then
  # rejects every later stage update.
  method_path = "${replace(trimprefix(aws_api_gateway_resource.summary.path, "/"), "/", "~1")}/GET"

  settings {
    metrics_enabled        = true
    caching_enabled        = true
    cache_ttl_in_seconds   = var.api_cache_ttl_seconds
    cache_data_encrypted   = true
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit

    # Clients cannot invalidate entries with "Cache-Control: max-age=0".
    require_authorization_for_cache_control    = true
    unauthorized_cache_control_header_strategy = "SUCCEED_WITHOUT_RESPONSE_HEADER"
  }
}
