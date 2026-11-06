output "thing_name" {
  value = aws_iot_thing.truck.name
}

output "certificate_arn" {
  value = aws_iot_certificate.truck.arn
}

output "cert_pem_path" {
  value = local_sensitive_file.cert_pem.filename
}

output "private_key_path" {
  value = local_sensitive_file.private_key.filename
}

output "telemetry_topic" {
  value = "coldchain/telemetry/${var.device_id}"
}

output "firehose_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.archive.name
}
