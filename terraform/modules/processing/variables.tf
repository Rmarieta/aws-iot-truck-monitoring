variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "input_stream_arn" {
  type = string
}

variable "input_stream_name" {
  type = string
}

variable "window_minutes" {
  type    = number
  default = 5
}

variable "battery_window_minutes" {
  description = "Tumbling window for the sustained-low-battery-while-moving detector. Short (e.g. 1) for testing; longer for production."
  type        = number
  default     = 1
}

variable "event_bus_name" {
  description = "EventBridge bus the excursion-forwarder Lambda publishes to."
  type        = string
  default     = "default"
}
