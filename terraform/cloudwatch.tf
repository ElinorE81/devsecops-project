# ── Log Groups ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${local.name_prefix}/app"
  retention_in_days = 30

  tags = { Name = "${local.name_prefix}-app-logs" }
}

# ── WAF BlockedRequests Alarm ─────────────────────────────────────────────────
# Fires when the RateLimitRule blocks ≥ threshold requests in a single
# 1-minute evaluation period, which indicates an active Layer 7 flood.

resource "aws_cloudwatch_metric_alarm" "waf_blocked_requests" {
  alarm_name          = "${local.name_prefix}-waf-blocked-requests"
  alarm_description   = "WAF is blocking requests — possible Layer 7 flood in progress. Check Splunk dashboard."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_blocked_requests_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.main.name
    Region = var.aws_region
    Rule   = "RateLimitRule"
  }

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]
}

# ── SNS Topic ─────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "security_alerts" {
  name = "${local.name_prefix}-security-alerts"

  tags = { Name = "${local.name_prefix}-security-alerts" }
}

# Email subscription — AWS sends a confirmation email on first apply;
# the admin must click the link before alerts are delivered.
resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# n8n webhook subscription — SNS will POST a SubscriptionConfirmation request
# to n8n when this resource is created. The n8n Webhook trigger node handles
# SNS confirmation automatically; ensure n8n is running and ngrok is active
# before running terraform apply.
resource "aws_sns_topic_subscription" "n8n_webhook" {
  count     = var.n8n_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "https"
  endpoint  = var.n8n_webhook_url

  # Set to false so Terraform does not block waiting for n8n to confirm.
  # The subscription becomes active once n8n responds to the confirmation POST.
  endpoint_auto_confirms = false
}
