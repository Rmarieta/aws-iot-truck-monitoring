output "timestream_database_name" {
  value = aws_timestreamwrite_database.telemetry.database_name
}

output "timestream_table_name" {
  value = aws_timestreamwrite_table.readings.table_name
}

output "timestream_table_arn" {
  value = aws_timestreamwrite_table.readings.arn
}

output "raw_bucket_name" {
  value = aws_s3_bucket.raw.bucket
}

output "raw_bucket_arn" {
  value = aws_s3_bucket.raw.arn
}

output "devices_table_name" {
  value = aws_dynamodb_table.devices.name
}

output "devices_table_arn" {
  value = aws_dynamodb_table.devices.arn
}
