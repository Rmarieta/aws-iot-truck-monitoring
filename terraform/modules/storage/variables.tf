variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "kms_key_arn" {
  description = "Project CMK ARN (encrypts Timestream, S3, DynamoDB at rest)."
  type        = string
}

variable "raw_expiration_days" {
  description = "Days before raw telemetry S3 objects expire."
  type        = number
  default     = 7
}

variable "telemetry_retention" {
  description = "Timestream memory/magnetic retention."
  type = object({
    memory_hours  = number
    magnetic_days = number
  })
  default = {
    memory_hours  = 24
    magnetic_days = 30
  }
}
