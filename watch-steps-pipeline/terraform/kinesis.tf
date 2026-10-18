resource "aws_kinesis_stream" "watch_steps" {
  name = var.stream_name
  # Default 24 h retention (enables replay of the last day). Not set explicitly:
  # AWS Academy denies kinesis:IncreaseStreamRetentionPeriod.

  # ON_DEMAND scales shards automatically with the write rate, so a burst of
  # requests through API Gateway does not hit a fixed per-shard limit.
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}
