# ===========================================================================
# Device connection-state tracking.
#
#   IoT Core lifecycle events  (device connects / disconnects)
#        -> published by the broker to $aws/events/presence/{connected,disconnected}
#   IoT Topic Rule             subscribes to those reserved topics
#        -> target: this Lambda
#   Lambda (presence-writer)   upserts conn_state onto the device's DynamoDB item
# ===========================================================================

# ---------------------------------------------------------------------------
# Lambda: presence-writer
# ---------------------------------------------------------------------------
data "archive_file" "presence" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/presence-writer"
  output_path = "${path.module}/build/presence-writer.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "presence" {
  name               = "${var.name_prefix}-presence-writer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "presence_logs" {
  role       = aws_iam_role.presence.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least-privilege: only UpdateItem on the one devices table, plus the KMS
# actions DynamoDB needs to write to a CMK-encrypted table.
data "aws_iam_policy_document" "presence" {
  statement {
    sid       = "DevicesUpsert"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.devices_table_arn]
  }
  statement {
    sid       = "KmsForDynamo"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "presence" {
  name   = "presence-writer"
  role   = aws_iam_role.presence.id
  policy = data.aws_iam_policy_document.presence.json
}

resource "aws_lambda_function" "presence" {
  function_name    = "${var.name_prefix}-presence-writer"
  role             = aws_iam_role.presence.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.presence.output_path
  source_code_hash = data.archive_file.presence.output_base64sha256
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      DEVICES_TABLE = var.devices_table_name
    }
  }
}

# ---------------------------------------------------------------------------
# IoT Topic Rule — subscribe to the reserved presence lifecycle topics.
#
# IoT Core publishes connect/disconnect lifecycle events to
#   $aws/events/presence/connected/{clientId}
#   $aws/events/presence/disconnected/{clientId}
# The rule subscribes to '$aws/events/presence/+/+' and forwards the raw payload
# straight to the Lambda:
#   { "clientId": "truck-0", "eventType": "connected"|"disconnected",
#     "timestamp": 1730470264000, "disconnectReason": "...", ... }
# ---------------------------------------------------------------------------
resource "aws_iot_topic_rule" "presence" {
  name        = replace("${var.name_prefix}_presence", "-", "_")
  enabled     = true
  sql         = "SELECT * FROM '$aws/events/presence/+/+'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.presence.arn
  }
}

resource "aws_lambda_permission" "presence" {
  statement_id  = "AllowIoTRuleInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presence.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.presence.arn
}
