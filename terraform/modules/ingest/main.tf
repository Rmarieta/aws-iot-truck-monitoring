# ===========================================================================
# Ingest — Kinesis Data Stream (the real-time hot path).
# The Rules Engine gets a fan-out branch into this stream; Flink reads it.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "retention_hours" {
  type    = number
  default = 24
}

resource "aws_kinesis_stream" "telemetry" {
  name             = "${var.name_prefix}-telemetry"
  retention_period = var.retention_hours

  # On-demand: no shard capacity planning, scales itself. Ideal for a load
  # that swings from a single phone to a large simulated fleet.
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  encryption_type = "KMS"
  kms_key_id      = var.kms_key_arn
}

output "stream_name" {
  value = aws_kinesis_stream.telemetry.name
}

output "stream_arn" {
  value = aws_kinesis_stream.telemetry.arn
}
