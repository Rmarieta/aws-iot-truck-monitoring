# ===========================================================================
# iot_core — identity for truck #0 + the Rules Engine fan-out.
#   Topic:  coldchain/telemetry/<device_id>
#   Rule fans each message out to:
#     1. Timestream  (hot query path)
#     2. Firehose    (-> S3 raw archive)
#     3. Kinesis     (windowed excursion detection, when configured)
# One real device is onboarded here; the fleet provisioning template reuses
# the SAME policy shape.
# ===========================================================================

# ---------------------------------------------------------------------------
# Thing + certificate (keys written locally, gitignored)
# ---------------------------------------------------------------------------
resource "aws_iot_thing" "truck" {
  name = var.device_id
}

resource "aws_iot_certificate" "truck" {
  active = true
}

resource "local_sensitive_file" "cert_pem" {
  content         = aws_iot_certificate.truck.certificate_pem
  filename        = "${var.cert_output_dir}/${var.device_id}.cert.pem"
  file_permission = "0600"
}

resource "local_sensitive_file" "private_key" {
  content         = aws_iot_certificate.truck.private_key
  filename        = "${var.cert_output_dir}/${var.device_id}.private.key"
  file_permission = "0600"
}

# ---------------------------------------------------------------------------
# Least-privilege device policy — this device may only touch its OWN topics
# and command topic (no fleet-wide wildcard).
# ---------------------------------------------------------------------------
resource "aws_iot_policy" "device" {
  name = "${var.name_prefix}-device-${var.device_id}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "arn:aws:iot:${var.region}:${var.account_id}:client/${var.device_id}"
      },
      {
        Effect = "Allow"
        Action = "iot:Publish"
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:topic/coldchain/telemetry/${var.device_id}",
          "arn:aws:iot:${var.region}:${var.account_id}:topic/coldchain/status/${var.device_id}",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Subscribe"
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:topicfilter/coldchain/cmd/${var.device_id}",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Receive"
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:topic/coldchain/cmd/${var.device_id}",
        ]
      },
    ]
  })
}

resource "aws_iot_policy_attachment" "device" {
  policy = aws_iot_policy.device.name
  target = aws_iot_certificate.truck.arn
}

resource "aws_iot_thing_principal_attachment" "truck" {
  thing     = aws_iot_thing.truck.name
  principal = aws_iot_certificate.truck.arn
}

# ---------------------------------------------------------------------------
# Firehose -> S3 archive path (the Rules Engine "archive" branch)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "firehose" {
  name = "${var.name_prefix}-firehose-to-s3"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = var.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "write-raw-bucket"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject",
        ]
        Resource = [var.raw_bucket_arn, "${var.raw_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "archive" {
  name        = "${var.name_prefix}-raw-archive"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = var.raw_bucket_arn
    buffering_interval  = 60
    buffering_size      = 5
    compression_format  = "GZIP"
    prefix              = "raw/dt=!{timestamp:yyyy-MM-dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"

    kms_key_arn = var.kms_key_arn
  }
}

# ---------------------------------------------------------------------------
# Scoped inline policy on the SHARED iot-rule-actions role (from security.tf):
# allow exactly the Timestream table + this Firehose stream, nothing wider.
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "rule_actions" {
  name = "m1-telemetry-fanout"
  role = var.iot_rule_actions_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["timestream:WriteRecords"]
        Resource = var.timestream_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["timestream:DescribeEndpoints"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
        Resource = aws_kinesis_firehose_delivery_stream.archive.arn
      },
      ], var.kinesis_stream_arn == "" ? [] : [
      {
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord"]
        Resource = var.kinesis_stream_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_key_arn
      },
    ])
  })
}

# ---------------------------------------------------------------------------
# Rules Engine fan-out rule
# ---------------------------------------------------------------------------
resource "aws_iot_topic_rule" "telemetry_fanout" {
  name    = "${replace(var.name_prefix, "-", "_")}_telemetry_fanout"
  enabled = true
  # Defense in depth: only forward genuine telemetry (a non-empty `ts`). A
  # message without `ts` (e.g. a stray status/Last-Will payload) would parse to
  # a null rowtime in Flink and crash-loop the detector job, and would also
  # dirty Timestream/Firehose. Filtering here protects every downstream action.
  sql         = "SELECT * FROM 'coldchain/telemetry/+' WHERE isUndefined(ts) = false AND ts <> ''"
  sql_version = "2016-03-23"

  # 1. hot path -> Timestream
  timestream {
    role_arn      = var.iot_rule_actions_role_arn
    database_name = var.timestream_database_name
    table_name    = var.timestream_table_name

    dimension {
      name  = "device_id"
      value = "$${topic(3)}"
    }

    # Stamp each record with the reading's OWN time, not ingest time. Without
    # this, a replayed (store-and-forward) reading would be stored at arrival
    # time and cluster at reconnect instead of backfilling its real slot.
    # `ts` is ISO-8601; convert to epoch milliseconds.
    timestamp {
      value = "$${time_to_epoch(ts, \"yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX\")}"
      unit  = "MILLISECONDS"
    }
  }

  # 2. archive -> Firehose -> S3
  firehose {
    role_arn             = var.iot_rule_actions_role_arn
    delivery_stream_name = aws_kinesis_firehose_delivery_stream.archive.name
    separator            = "\n"
  }

  # 3. Hot path -> Kinesis, for Flink windowed detection. Only wired when
  # a stream name is passed in, so deployments without it stay unchanged.
  dynamic "kinesis" {
    for_each = var.kinesis_stream_name == "" ? [] : [1]
    content {
      role_arn      = var.iot_rule_actions_role_arn
      stream_name   = var.kinesis_stream_name
      partition_key = "$${topic(3)}"
    }
  }
}
