variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "notification_email" {
  type = string
}

variable "event_bus_name" {
  type    = string
  default = "default"
}

variable "ack_timeout_seconds" {
  description = "How long to wait for an operator ack before escalating."
  type        = number
  default     = 300
}
