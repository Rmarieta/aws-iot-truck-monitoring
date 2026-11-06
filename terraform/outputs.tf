output "account_id" {
  description = "The AWS account this is deployed into."
  value       = local.account_id
}

output "kms_key_arn" {
  description = "Project CMK ARN (encrypts all data stores at rest)."
  value       = aws_kms_key.main.arn
}

output "kms_key_alias" {
  description = "Project CMK alias."
  value       = aws_kms_alias.main.name
}

output "iot_rule_actions_role_arn" {
  description = "IAM role assumed by IoT Rules Engine actions."
  value       = aws_iam_role.iot_rule_actions.arn
}

# ---- Devices ----
output "device_thing_name" {
  description = "The onboarded device (phone = truck #0)."
  value       = module.iot_core.thing_name
}

output "device_telemetry_topic" {
  description = "MQTT topic the phone publisher sends to."
  value       = module.iot_core.telemetry_topic
}

output "device_cert_path" {
  description = "Local path to the device certificate (gitignored)."
  value       = module.iot_core.cert_pem_path
}

output "device_private_key_path" {
  description = "Local path to the device private key (gitignored)."
  value       = module.iot_core.private_key_path
}

output "timestream_table" {
  description = "Timestream database.table for telemetry queries."
  value       = "${module.storage.timestream_database_name}.${module.storage.timestream_table_name}"
}

output "raw_archive_bucket" {
  description = "S3 bucket holding the raw telemetry archive."
  value       = module.storage.raw_bucket_name
}

output "dashboard_readings_url" {
  description = "Query this for truck readings; also what web/index.html polls."
  value       = module.dashboard.readings_url
}

output "dashboard_url" {
  description = "Hosted dashboard (CloudFront HTTPS URL)."
  value       = module.dashboard.dashboard_url
}

# ---- Processing & alerting ----
output "flink_application_name" {
  description = "Managed Flink app — start/stop with make flink-start / flink-stop."
  value       = module.processing.flink_application_name
}

output "telemetry_stream_name" {
  description = "Kinesis hot-path stream the Rules Engine feeds and Flink reads."
  value       = module.ingest.stream_name
}

output "alerts_topic_arn" {
  description = "SNS topic for excursion alerts (confirm the email subscription once)."
  value       = module.workflow.alerts_topic_arn
}

output "excursion_state_machine_arn" {
  description = "Step Functions workflow started on excursion.detected."
  value       = module.workflow.state_machine_arn
}

# ---- Simulated fleet ----
output "fleet_ecr_repository_url" {
  description = "Push the simulator image here (make fleet-build)."
  value       = module.fleet.ecr_repository_url
}

output "fleet_ecs_cluster" {
  description = "ECS cluster running the simulated trucks."
  value       = module.fleet.ecs_cluster_name
}

output "fleet_ecs_service" {
  description = "Scale this service's desired-count to set the fleet size (make fleet SIZE=N)."
  value       = module.fleet.ecs_service_name
}

output "fleet_group_name" {
  description = "IoT thing group holding the simulated trucks."
  value       = module.fleet.fleet_group_name
}
