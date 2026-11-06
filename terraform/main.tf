# ===========================================================================
# Cold-Chain Logistics Monitoring — root module
# ---------------------------------------------------------------------------
# Composes the platform from focused modules: shared foundations (KMS + base
# IAM in security.tf), then ingest, storage, processing, alerting, the read
# API, and device connection-state tracking.
# ===========================================================================

# Discover the account id for globally-unique bucket names, so it never has to
# be hardcoded or committed (account-agnostic config).
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ATS data endpoint, resolved live (fed to the simulated-fleet tasks).
data "aws_iot_endpoint" "ats" {
  endpoint_type = "iot:Data-ATS"
}

# ---------------------------------------------------------------------------
# IoT Core identity, Rules Engine fan-out, Timestream, dashboard
# ---------------------------------------------------------------------------
module "storage" {
  source = "./modules/storage"

  name_prefix         = var.name_prefix
  account_id          = local.account_id
  kms_key_arn         = aws_kms_key.main.arn # single-apply dependency, by attribute
  raw_expiration_days = var.raw_expiration_days
}

module "iot_core" {
  source = "./modules/iot_core"

  name_prefix = var.name_prefix
  account_id  = local.account_id
  region      = var.region
  kms_key_arn = aws_kms_key.main.arn

  iot_rule_actions_role_arn  = aws_iam_role.iot_rule_actions.arn
  iot_rule_actions_role_name = aws_iam_role.iot_rule_actions.name

  timestream_database_name = module.storage.timestream_database_name
  timestream_table_name    = module.storage.timestream_table_name
  timestream_table_arn     = module.storage.timestream_table_arn
  raw_bucket_arn           = module.storage.raw_bucket_arn

  # Hot-path branch into Kinesis (empty when no stream is wired).
  kinesis_stream_arn  = module.ingest.stream_arn
  kinesis_stream_name = module.ingest.stream_name
}

module "dashboard" {
  source = "./modules/dashboard"

  name_prefix              = var.name_prefix
  timestream_database_name = module.storage.timestream_database_name
  timestream_table_name    = module.storage.timestream_table_name
  timestream_table_arn     = module.storage.timestream_table_arn

  kms_key_arn = aws_kms_key.main.arn

  dynamodb_table_name = module.storage.devices_table_name
  dynamodb_table_arn  = module.storage.devices_table_arn

  account_id = local.account_id
}

# ---------------------------------------------------------------------------
# Kinesis hot path, Flink windowed detection, Step Functions, SNS
# ---------------------------------------------------------------------------
module "ingest" {
  source = "./modules/ingest"

  name_prefix     = var.name_prefix
  kms_key_arn     = aws_kms_key.main.arn
  retention_hours = var.telemetry_retention_hours
}

module "processing" {
  source = "./modules/processing"

  name_prefix       = var.name_prefix
  region            = var.region
  kms_key_arn       = aws_kms_key.main.arn
  input_stream_arn  = module.ingest.stream_arn
  input_stream_name = module.ingest.stream_name
  window_minutes    = var.excursion_window_minutes
}

module "workflow" {
  source = "./modules/workflow"

  name_prefix         = var.name_prefix
  region              = var.region
  account_id          = local.account_id
  kms_key_arn         = aws_kms_key.main.arn
  notification_email  = var.notification_email
  ack_timeout_seconds = var.excursion_window_minutes * 60
}

# ---------------------------------------------------------------------------
# Device connection-state tracking (presence -> DynamoDB)
# ---------------------------------------------------------------------------
module "presence" {
  source = "./modules/presence"

  name_prefix        = var.name_prefix
  kms_key_arn        = aws_kms_key.main.arn
  devices_table_name = module.storage.devices_table_name
  devices_table_arn  = module.storage.devices_table_arn
}

# ---------------------------------------------------------------------------
# Simulated fleet — N Fargate tasks, one virtual truck each (scale demo).
# Platform only; the fleet population (the truck-<hash> things) is created at
# RUNTIME by each task, not declared here. desired_count starts at 0 so apply
# never launches trucks — the Makefile scales it.
# ---------------------------------------------------------------------------
module "fleet" {
  source = "./modules/fleet"

  name_prefix              = var.name_prefix
  account_id               = local.account_id
  region                   = var.region
  iot_endpoint             = data.aws_iot_endpoint.ats.endpoint_address
  publish_interval_seconds = var.fleet_publish_interval_seconds
  offline_pct              = var.fleet_offline_pct
}

# The real device (truck-0) joins the SAME fleet group as the simulated trucks
# so it appears in the fleet view / device filter alongside them — but keeps
# its OWN per-device certificate (declared in iot_core), unlike the sims which
# share one cert. Membership only; truck-0's identity is unchanged.
resource "aws_iot_thing_group_membership" "truck0_in_fleet" {
  thing_group_name = module.fleet.fleet_group_name
  thing_name       = module.iot_core.thing_name
}
