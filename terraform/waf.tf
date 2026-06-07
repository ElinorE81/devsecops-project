# ── WAF IP Set: Dynamic Blocklist ────────────────────────────────────────────
# Starts empty. The n8n SOC workflow adds attacker IPs here when the admin
# clicks "Block IP Permanently" in the Human-in-the-Loop alert email.

resource "aws_wafv2_ip_set" "blocklist" {
  name               = "${local.name_prefix}-blocklist"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = []   # managed dynamically by n8n via the WAF API

  tags = { Name = "${local.name_prefix}-blocklist" }
}

# ── WAF Web ACL ───────────────────────────────────────────────────────────────

resource "aws_wafv2_web_acl" "main" {
  name  = "${local.name_prefix}-web-acl"
  scope = "REGIONAL" # REGIONAL for ALB; CLOUDFRONT for distributions

  default_action {
    allow {}
  }

  # Priority 0 — evaluated FIRST. Permanently blocked IPs are rejected before
  # they ever reach the rate-limit rule, keeping blocked counts clean.
  rule {
    name     = "BlocklistedIPs"
    priority = 0

    action {
      block {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.blocklist.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-blocklisted-ips"
      sampled_requests_enabled   = true
    }
  }

  # Priority 1 — rate limiting rule. Blocks any IP that exceeds the request
  # threshold within a rolling 5-minute window (the Layer 7 flood detector).
  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-rate-limit-rule"
      sampled_requests_enabled   = true
    }
  }

  # Web ACL-level metrics (aggregated across all rules)
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-web-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.name_prefix}-web-acl" }
}

# ── Associate WAF with the ALB ────────────────────────────────────────────────

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# ── WAF Logging → Kinesis Firehose ────────────────────────────────────────────
# AWS requires the target Firehose stream name to start with "aws-waf-logs-"

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_to_splunk.arn]

  # Redact sensitive headers from WAF logs before they leave AWS
  redacted_fields {
    single_header { name = "authorization" }
  }
  redacted_fields {
    single_header { name = "cookie" }
  }
}
