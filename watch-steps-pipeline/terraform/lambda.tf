data "aws_iam_role" "lab_role" {
  name = var.lab_role_name
}

locals {
  # Empty values are dropped: Serverless gets REDSHIFT_WORKGROUP,
  # provisioned gets REDSHIFT_CLUSTER_ID + REDSHIFT_DB_USER.
  redshift_env = { for k, v in {
    REDSHIFT_WORKGROUP  = local.redshift_data_target.workgroup_name
    REDSHIFT_CLUSTER_ID = local.redshift_data_target.cluster_identifier
    REDSHIFT_DB_USER    = local.redshift_data_target.db_user
    REDSHIFT_DATABASE   = var.redshift_database
    TARGET_TABLE        = "public.watch_steps"
  } : k => v if v != null }
}

# ---------------------------------------------------------------------------
# Processor: Kinesis -> Redshift Serverless
# ---------------------------------------------------------------------------
data "archive_file" "processor" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/processor"
  output_path = "${path.module}/build/processor.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "processor" {
  function_name    = var.lambda_function_name
  role             = data.aws_iam_role.lab_role.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = local.redshift_env
  }

  # The table must exist (and be granted) before records start flowing in.
  depends_on = [
    aws_cloudwatch_log_group.processor,
    aws_redshiftdata_statement.grants,
  ]
}

resource "aws_lambda_event_source_mapping" "kinesis_to_processor" {
  event_source_arn  = aws_kinesis_stream.watch_steps.arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "LATEST"

  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  # Up to N concurrent batches per shard (order is still kept per device_id).
  parallelization_factor         = 2
  bisect_batch_on_function_error = true
  maximum_retry_attempts         = 2
  function_response_types        = ["ReportBatchItemFailures"]
}

# ---------------------------------------------------------------------------
# Ingest: API Gateway POST /steps -> Kinesis
# ---------------------------------------------------------------------------
data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/ingest"
  output_path = "${path.module}/build/ingest.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.ingest_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "ingest" {
  function_name    = var.ingest_function_name
  role             = data.aws_iam_role.lab_role.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      STREAM_NAME = aws_kinesis_stream.watch_steps.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest]
}

# ---------------------------------------------------------------------------
# Query: API Gateway GET /steps/summary -> Redshift Serverless (cached by API Gateway)
# ---------------------------------------------------------------------------
data "archive_file" "query" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/query"
  output_path = "${path.module}/build/query.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${var.query_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "query" {
  function_name    = var.query_function_name
  role             = data.aws_iam_role.lab_role.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.query.output_path
  source_code_hash = data.archive_file.query.output_base64sha256
  timeout          = 29 # API Gateway's integration timeout
  memory_size      = 256

  environment {
    variables = local.redshift_env
  }

  depends_on = [
    aws_cloudwatch_log_group.query,
    aws_redshiftdata_statement.grants,
  ]
}
