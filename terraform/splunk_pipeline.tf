data "aws_caller_identity" "current" {}

# ── S3 Bucket: WAF Log Backup ─────────────────────────────────────────────────
# Firehose writes here on delivery failure (or all events if s3_backup_mode = AllEvents).

resource "aws_s3_bucket" "waf_logs" {
  # Account ID suffix guarantees global uniqueness without random strings
  bucket        = "${local.name_prefix}-waf-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${local.name_prefix}-waf-logs" }
}

resource "aws_s3_bucket_versioning" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  bucket                  = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 90 }
  }
}

# ── Kinesis Firehose: WAF Logs → Splunk HEC (with S3 failure backup) ─────────
# AWS enforces that WAF log delivery stream names begin with "aws-waf-logs-".

resource "aws_kinesis_firehose_delivery_stream" "waf_to_splunk" {
  name        = "aws-waf-logs-${local.name_prefix}"
  destination = "splunk"

  splunk_configuration {
    hec_endpoint               = var.splunk_hec_endpoint
    hec_token                  = var.splunk_hec_token
    hec_endpoint_type          = "Event"
    hec_acknowledgment_timeout = 600
    retry_duration             = 300

    # Failed events fall back to S3 so no WAF log is lost if Splunk is
    # temporarily unreachable (e.g. during ngrok reconnection).
    s3_backup_mode = "FailedEventsOnly"

    s3_configuration {
      role_arn           = aws_iam_role.firehose.arn
      bucket_arn         = aws_s3_bucket.waf_logs.arn
      buffering_size     = 5
      buffering_interval = 60
      compression_format = "GZIP"
      prefix             = "waf-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix = "waf-logs-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/"
    }
  }

  tags = { Name = "${local.name_prefix}-waf-firehose" }
}

# ── Lambda: CloudWatch App Logs → Splunk HEC ─────────────────────────────────

data "archive_file" "cwlogs_to_splunk" {
  type        = "zip"
  source_file = "${path.module}/lambda/cwlogs_to_splunk.py"
  output_path = "${path.module}/lambda/cwlogs_to_splunk.zip"
}

resource "aws_lambda_function" "cwlogs_to_splunk" {
  function_name    = "${local.name_prefix}-cwlogs-to-splunk"
  role             = aws_iam_role.lambda_cwlogs_to_splunk.arn
  filename         = data.archive_file.cwlogs_to_splunk.output_path
  source_code_hash = data.archive_file.cwlogs_to_splunk.output_base64sha256
  runtime          = "python3.11"
  handler          = "cwlogs_to_splunk.handler"
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      # Full URL including /services/collector path — distinct from the Firehose
      # base endpoint which has the path appended by AWS automatically.
      SPLUNK_HEC_URL   = local.splunk_hec_events_url
      SPLUNK_HEC_TOKEN = var.splunk_hec_token
      SPLUNK_INDEX     = var.splunk_index
    }
  }

  tags = { Name = "${local.name_prefix}-cwlogs-to-splunk" }
}

# Grant CloudWatch Logs permission to invoke this Lambda
resource "aws_lambda_permission" "allow_cloudwatch_logs" {
  statement_id  = "AllowCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cwlogs_to_splunk.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.app.arn}:*"
}

# Subscription filter — every app log event triggers the Lambda forwarder.
# filter_pattern = "" means all events are forwarded (no pre-filtering).
resource "aws_cloudwatch_log_subscription_filter" "app_to_splunk" {
  name            = "${local.name_prefix}-app-to-splunk"
  log_group_name  = aws_cloudwatch_log_group.app.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.cwlogs_to_splunk.arn

  depends_on = [aws_lambda_permission.allow_cloudwatch_logs]
}
