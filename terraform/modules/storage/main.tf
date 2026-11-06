# ===========================================================================
# Storage — one store per access pattern
#   - Timestream : time-series telemetry (the hot query path)
#   - S3         : raw-telemetry archive (cheap, queried later via Athena)
#   - DynamoDB   : device registry / current trip + connection state
# All encrypted with the project CMK (passed in by attribute).
# ===========================================================================

# ---------------------------------------------------------------------------
# Timestream — telemetry
# ---------------------------------------------------------------------------
resource "aws_timestreamwrite_database" "telemetry" {
  database_name = "${var.name_prefix}_telemetry"
  kms_key_id    = var.kms_key_arn
}

resource "aws_timestreamwrite_table" "readings" {
  database_name = aws_timestreamwrite_database.telemetry.database_name
  table_name    = "readings"

  retention_properties {
    memory_store_retention_period_in_hours  = var.telemetry_retention.memory_hours
    magnetic_store_retention_period_in_days = var.telemetry_retention.magnetic_days
  }
}

# ---------------------------------------------------------------------------
# S3 — raw telemetry archive
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "raw" {
  bucket = "${var.name_prefix}-raw-telemetry-${var.account_id}"
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "expire-raw"
    status = "Enabled"
    filter {}
    expiration {
      days = var.raw_expiration_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — device registry / current state
#   PK = device_id (e.g. "truck-0"). Single-digit-ms lookups for the dashboard.
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "devices" {
  name         = "${var.name_prefix}-devices"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }
}
