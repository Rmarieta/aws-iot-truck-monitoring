# ===========================================================================
# KMS + base IAM foundations
# ---------------------------------------------------------------------------
# One customer-managed CMK for the whole project (encrypts Timestream,
# DynamoDB, S3, Kinesis, SNS, CloudWatch Logs at rest). Service principals
# are granted via the key policy.
# ===========================================================================

data "aws_region" "current" {}

resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} project CMK (Timestream/DynamoDB/S3/Kinesis/SNS)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowAwsServicesToUseTheKey"
        Effect = "Allow"
        Principal = {
          Service = [
            "iot.amazonaws.com",
            "timestream.amazonaws.com",
            "dynamodb.amazonaws.com",
            "s3.amazonaws.com",
            "kinesis.amazonaws.com",
            "sns.amazonaws.com",
            "events.amazonaws.com",
            "logs.${data.aws_region.current.name}.amazonaws.com",
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------------------------------------------------------------------------
# Base IoT Rules Engine role — assumed by the IoT service so rule actions can
# write to Timestream / Kinesis / Firehose. Scoped per-service via
# attached inline policies (no wildcard resources).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "iot_rule_actions" {
  name = "${var.name_prefix}-iot-rule-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:iot:${data.aws_region.current.name}:${local.account_id}:rule/*" }
      }
    }]
  })
}
