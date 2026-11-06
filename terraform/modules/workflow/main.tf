# ===========================================================================
# Workflow — the spoilage-response pipeline.
#   EventBridge (excursion.detected) -> Step Functions -> SNS (email/SMS)
#
# The state machine: notify operators, wait for the ack window, then escalate
# if still unacknowledged. A real deployment would use a task token + a human
# ack callback; for the demo the "wait then escalate" timer shows the shape
# without needing an ack UI.
# ===========================================================================

# ---------------------------------------------------------------------------
# SNS — operator alerts. The email subscription needs a one-time confirmation
# click (AWS sends a confirmation mail to notification_email on apply).
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-excursion-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ---------------------------------------------------------------------------
# Step Functions state machine
# ---------------------------------------------------------------------------
resource "aws_iam_role" "sfn" {
  name = "${var.name_prefix}-excursion-workflow"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "publish-alerts"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_sfn_state_machine" "excursion" {
  name     = "${var.name_prefix}-excursion-response"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "Cold-chain excursion response: notify -> wait for ack -> escalate"
    StartAt = "NotifyOperators"
    States = {
      NotifyOperators = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.alerts.arn
          "Subject.$" = "States.Format('COLD-CHAIN EXCURSION: {} ({})', $.detail.device_id, $.detail.cargo_type)"
          "Message.$" = "States.Format('Truck {} carrying {} stayed at min {}C over the window ending {}. Acknowledge within ${var.ack_timeout_seconds}s or this escalates.', $.detail.device_id, $.detail.cargo_type, $.detail.min_temp_c, $.detail.window_end)"
        }
        Next = "WaitForAck"
      }
      WaitForAck = {
        Type    = "Wait"
        Seconds = var.ack_timeout_seconds
        Next    = "Escalate"
      }
      Escalate = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.alerts.arn
          "Subject.$" = "States.Format('ESCALATION — unacknowledged excursion: {}', $.detail.device_id)"
          "Message.$" = "States.Format('Excursion {} on truck {} was NOT acknowledged in time. Escalating.', $.detail.excursion_id, $.detail.device_id)"
        }
        End = true
      }
    }
  })
}

# ---------------------------------------------------------------------------
# EventBridge rule: excursion.detected -> start the state machine
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "excursion" {
  name           = "${var.name_prefix}-excursion-detected"
  event_bus_name = var.event_bus_name
  event_pattern = jsonencode({
    source      = ["coldchain.excursion-detector"]
    detail-type = ["excursion.detected"]
  })
}

resource "aws_iam_role" "events" {
  name = "${var.name_prefix}-events-to-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events" {
  name = "start-sfn"
  role = aws_iam_role.events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.excursion.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "sfn" {
  rule           = aws_cloudwatch_event_rule.excursion.name
  event_bus_name = var.event_bus_name
  arn            = aws_sfn_state_machine.excursion.arn
  role_arn       = aws_iam_role.events.arn
}

# ===========================================================================
# Battery advisory path — a SECOND event type routed DIFFERENTLY.
#
#   battery.low_moving -> SNS (advisory "schedule a charge") directly.
#
# Deliberately NOT the notify->wait->escalate workflow: a sustained-low-battery
# truck is an operational warning, not a spoilage emergency. This is the payoff
# of putting an event bus at the detection boundary — the SAME producer/stream
# feeds two event types that EventBridge routes to two different responses by
# DetailType, declaratively, with no change to the detector or the forwarder.
# ===========================================================================
resource "aws_cloudwatch_event_rule" "battery_low_moving" {
  name           = "${var.name_prefix}-battery-low-moving"
  event_bus_name = var.event_bus_name
  event_pattern = jsonencode({
    source      = ["coldchain.excursion-detector"]
    detail-type = ["battery.low_moving"]
  })
}

# EventBridge targets the SNS topic directly (no Step Functions, no Lambda).
resource "aws_cloudwatch_event_target" "battery_sns" {
  rule           = aws_cloudwatch_event_rule.battery_low_moving.name
  event_bus_name = var.event_bus_name
  arn            = aws_sns_topic.alerts.arn

  # Shape a readable advisory message from the event detail.
  input_transformer {
    input_paths = {
      device  = "$.detail.device_id"
      battery = "$.detail.max_battery_pct"
      wend    = "$.detail.window_end"
    }
    input_template = "\"LOW BATTERY WHILE MOVING: truck <device> stayed under 20% (max <battery>%) and kept moving through the window ending <wend>. Schedule charging to avoid losing reefer power.\""
  }
}

# Allow EventBridge to publish to the (KMS-encrypted) SNS topic.
resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.battery_low_moving.arn }
      }
    }]
  })
}
