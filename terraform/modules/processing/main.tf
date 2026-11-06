# ===========================================================================
# Managed Service for Apache Flink (Flink SQL) excursion detector + the
# Kinesis->EventBridge forwarder.
#
# COST NOTE: a Flink application bills per KPU (~EUR 0.11/hr) WHENEVER it is
# RUNNING. It is created in the STOPPED state (start_application = false) and
# started on demand via `make flink-start`. Stop it with `make flink-stop`
# when you are done demoing, or it runs up ~EUR 80/month.
# ===========================================================================

# ---------------------------------------------------------------------------
# Output stream: Flink writes detected excursions here.
# ---------------------------------------------------------------------------
resource "aws_kinesis_stream" "excursions" {
  name             = "${var.name_prefix}-excursions"
  retention_period = 24
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
  encryption_type = "KMS"
  kms_key_id      = var.kms_key_arn
}

# ---------------------------------------------------------------------------
# Package the Flink app (SQL + PyFlink loader) and upload to S3.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "flink_code" {
  bucket = "${var.name_prefix}-flink-code-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_public_access_block" "flink_code" {
  bucket                  = aws_s3_bucket.flink_code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "me" {}

data "archive_file" "flink" {
  type        = "zip"
  source_dir  = "${path.root}/../flink"
  output_path = "${path.module}/build/flink-app.zip"
}

resource "aws_s3_object" "flink" {
  bucket = aws_s3_bucket.flink_code.id
  key    = "flink-app-${data.archive_file.flink.output_md5}.zip"
  source = data.archive_file.flink.output_path
  etag   = data.archive_file.flink.output_md5
}

# ---------------------------------------------------------------------------
# IAM role for the Flink application: read input stream, write output stream,
# read its code from S3, and CloudWatch logs.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "flink" {
  name = "${var.name_prefix}-flink"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "kinesisanalytics.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flink" {
  name = "flink-io"
  role = aws_iam_role.flink.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards", "kinesis:SubscribeToShard", "kinesis:DescribeStreamConsumer", "kinesis:DescribeStreamSummary"]
        Resource = [var.input_stream_arn, aws_kinesis_stream.excursions.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord", "kinesis:PutRecords"]
        Resource = aws_kinesis_stream.excursions.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.flink_code.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.flink_code.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "flink" {
  name              = "/aws/kinesis-analytics/${var.name_prefix}-detector"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "flink" {
  name           = "detector"
  log_group_name = aws_cloudwatch_log_group.flink.name
}

# ---------------------------------------------------------------------------
# The Flink application itself. Created STOPPED (start_application = false).
# ---------------------------------------------------------------------------
resource "aws_kinesisanalyticsv2_application" "detector" {
  name                   = "${var.name_prefix}-detector"
  runtime_environment    = "FLINK-1_18"
  service_execution_role = aws_iam_role.flink.arn
  start_application      = false

  application_configuration {
    application_code_configuration {
      code_content {
        s3_content_location {
          bucket_arn = aws_s3_bucket.flink_code.arn
          file_key   = aws_s3_object.flink.key
        }
      }
      code_content_type = "ZIPFILE"
    }

    environment_properties {
      property_group {
        property_group_id = "detector"
        property_map = {
          input_stream   = var.input_stream_name
          output_stream  = aws_kinesis_stream.excursions.name
          region         = var.region
          window         = tostring(var.window_minutes)
          battery_window = tostring(var.battery_window_minutes)
        }
      }

      # Tells Managed Flink this is a PyFlink app and names the entry file,
      # so it does NOT look for a JAR (the "No valid JAR" error without this).
      property_group {
        property_group_id = "kinesis.analytics.flink.run.options"
        property_map = {
          python  = "main.py"
          jarfile = "lib/flink-sql-connector-kinesis-4.3.0-1.18.jar"
        }
      }
    }

    flink_application_configuration {
      parallelism_configuration {
        configuration_type = "DEFAULT"
      }
    }
  }

  cloudwatch_logging_options {
    log_stream_arn = aws_cloudwatch_log_stream.flink.arn
  }
}

# ---------------------------------------------------------------------------
# Forwarder Lambda: excursions Kinesis stream -> EventBridge.
# ---------------------------------------------------------------------------
data "archive_file" "forwarder" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/excursion-forwarder"
  output_path = "${path.module}/build/excursion-forwarder.zip"
}

resource "aws_iam_role" "forwarder" {
  name = "${var.name_prefix}-excursion-forwarder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "forwarder_logs" {
  role       = aws_iam_role.forwarder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "forwarder" {
  name = "forward-excursions"
  role = aws_iam_role.forwarder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards", "kinesis:DescribeStreamSummary"]
        Resource = aws_kinesis_stream.excursions.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "arn:aws:events:${var.region}:${data.aws_caller_identity.me.account_id}:event-bus/${var.event_bus_name}"
      },
    ]
  })
}

resource "aws_lambda_function" "forwarder" {
  function_name    = "${var.name_prefix}-excursion-forwarder"
  role             = aws_iam_role.forwarder.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.forwarder.output_path
  source_code_hash = data.archive_file.forwarder.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      EVENT_BUS_NAME = var.event_bus_name
    }
  }
}

resource "aws_lambda_event_source_mapping" "excursions" {
  event_source_arn  = aws_kinesis_stream.excursions.arn
  function_name     = aws_lambda_function.forwarder.arn
  starting_position = "LATEST"
  batch_size        = 10
}
