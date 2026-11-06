variable "name_prefix" {
  description = "Resource name prefix (e.g. coldchain)."
  type        = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "iot_endpoint" {
  description = "IoT Core ATS data endpoint (aws iot describe-endpoint --endpoint-type iot:Data-ATS)."
  type        = string
}

variable "fleet_size" {
  description = "Initial desired task count. Kept at 0 so apply never launches trucks; the Makefile scales it."
  type        = number
  default     = 0
}

variable "publish_interval_seconds" {
  description = "Seconds between telemetry messages per truck."
  type        = number
  default     = 5
}

variable "offline_pct" {
  description = "Chance (0-100) a truck goes offline on a tick, to exercise store-and-forward at scale."
  type        = number
  default     = 0
}
