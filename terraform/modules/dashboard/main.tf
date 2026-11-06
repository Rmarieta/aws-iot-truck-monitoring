# ===========================================================================
# Dashboard — the read path: a page that shows the truck's live position.
#   Lambda (queries Timestream) <- API Gateway HTTP API (CORS)
#   Static map page served from S3 (website hosting, demo-simple).
# ===========================================================================

# ---------------------------------------------------------------------------
# Lambda: query Timestream for recent readings
# ---------------------------------------------------------------------------
data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/dashboard-api"
  output_path = "${path.module}/build/dashboard-api.zip"
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

resource "aws_iam_role" "api" {
  name               = "${var.name_prefix}-dashboard-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "api_logs" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Timestream reads need the table Select plus the account-level DescribeEndpoints
# (which does not support resource scoping).
data "aws_iam_policy_document" "api" {
  statement {
    sid       = "TimestreamSelect"
    actions   = ["timestream:Select"]
    resources = [var.timestream_table_arn]
  }
  statement {
    sid       = "TimestreamEndpoints"
    actions   = ["timestream:DescribeEndpoints"]
    resources = ["*"]
  }
  statement {
    sid       = "KMS"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "DynamoDB"
    actions   = ["dynamodb:GetItem"]
    resources = [var.dynamodb_table_arn]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "dashboard-api"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.name_prefix}-dashboard-api"
  role             = aws_iam_role.api.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  memory_size      = 256
  timeout          = 30

  environment {
    variables = {
      TIMESTREAM_DB    = var.timestream_database_name
      TIMESTREAM_TABLE = var.timestream_table_name
      DYNAMODB_TABLE   = var.dynamodb_table_name
    }
  }
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API -> Lambda
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.name_prefix}-dashboard"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "readings" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /readings"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "stats" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /stats"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "devices" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /devices"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Static hosting: private S3 bucket + CloudFront (Origin Access Control).
# The bucket stays private (no public website hosting); CloudFront is its only
# reader, serving the page over HTTPS. config.js is generated here from the API
# URL so the hosted page self-configures and no account-specific URL is committed.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "site" {
  bucket = "${var.name_prefix}-dashboard-${var.account_id}"
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name_prefix}-dashboard-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.name_prefix} cold-chain dashboard"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-dashboard"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-dashboard"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # AWS managed "CachingOptimized" policy.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# CloudFront (via OAC) is the only principal allowed to read the bucket.
data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}

# Upload the page. content_type matters so the browser renders, not downloads.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  source       = "${path.root}/../web/index.html"
  etag         = filemd5("${path.root}/../web/index.html")
  content_type = "text/html"
}

# Generated config.js: injects the deployed API base URL into the hosted page,
# so the committed index.html stays environment-agnostic and no URL is baked in.
resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.site.id
  key          = "config.js"
  content      = "window.READINGS_URL = \"${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/readings\";\n"
  content_type = "application/javascript"
}
