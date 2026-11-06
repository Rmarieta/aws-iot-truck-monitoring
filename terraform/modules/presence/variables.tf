variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  description = "Project CMK ARN (DynamoDB write needs Decrypt + GenerateDataKey)."
  type        = string
}

variable "devices_table_name" {
  description = "DynamoDB devices table name (connection state is upserted here)."
  type        = string
}

variable "devices_table_arn" {
  description = "DynamoDB devices table ARN (scopes the UpdateItem permission)."
  type        = string
}
