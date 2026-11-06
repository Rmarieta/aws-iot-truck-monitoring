variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "iot_rule_actions_role_arn" {
  description = "Base IoT rule-actions role (from security.tf), assumed by rule actions."
  type        = string
}

variable "iot_rule_actions_role_name" {
  description = "Name of that role, so this module can attach a scoped inline policy to it."
  type        = string
}

variable "device_id" {
  description = "The real device onboarded as truck #0 (the phone)."
  type        = string
  default     = "truck-0"
}

variable "timestream_database_name" {
  type = string
}

variable "timestream_table_name" {
  type = string
}

variable "timestream_table_arn" {
  type = string
}

variable "raw_bucket_arn" {
  type = string
}

variable "cert_output_dir" {
  description = "Local dir where the device cert/key are written (gitignored)."
  type        = string
  default     = "../devices/phone/cert"
}

variable "kinesis_stream_arn" {
  description = "Hot-path Kinesis stream ARN. Empty = no Kinesis fan-out branch."
  type        = string
  default     = ""
}

variable "kinesis_stream_name" {
  description = "Hot-path Kinesis stream name."
  type        = string
  default     = ""
}
