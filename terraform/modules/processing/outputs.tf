output "flink_application_name" {
  description = "Managed Flink app name — use with make flink-start / flink-stop."
  value       = aws_kinesisanalyticsv2_application.detector.name
}

output "excursions_stream_name" {
  value = aws_kinesis_stream.excursions.name
}

output "excursions_stream_arn" {
  value = aws_kinesis_stream.excursions.arn
}
