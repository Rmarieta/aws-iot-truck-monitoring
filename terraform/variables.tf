variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI/SDK profile used for auth (SSO profile from ~/.aws/config)."
  type        = string
  default     = "training"
}

variable "name_prefix" {
  description = "Prefix for all resource names. Also used as the Project tag."
  type        = string
  default     = "coldchain"
}

variable "environment" {
  description = "Environment tag (demo/dev/prod)."
  type        = string
  default     = "demo"
}

variable "notification_email" {
  description = "Email subscribed to the SNS excursion-alerts topic. Set in terraform.tfvars (NOT committed)."
  type        = string
}

variable "cargo_thresholds_c" {
  description = <<-EOT
    Per-cargo-type upper temperature threshold in Celsius. An excursion is a
    reading above this value sustained for `excursion_window_minutes`.
  EOT
  type        = map(number)
  default = {
    vaccine = 8
    frozen  = -15
    produce = 12
  }
}

variable "excursion_window_minutes" {
  description = "Minutes a reading must stay above threshold before it is an excursion."
  type        = number
  default     = 5
}

variable "telemetry_retention_hours" {
  description = "Kinesis Data Stream retention in hours (>=24 for replay)."
  type        = number
  default     = 24
}

variable "raw_expiration_days" {
  description = "Days before raw telemetry S3 objects are deleted (demo cost control)."
  type        = number
  default     = 7
}

variable "fleet_publish_interval_seconds" {
  description = "Seconds between telemetry messages per simulated truck."
  type        = number
  default     = 5
}

variable "fleet_offline_pct" {
  description = "Chance (0-100) a simulated truck skips a tick, to exercise store-and-forward at scale."
  type        = number
  default     = 0
}
