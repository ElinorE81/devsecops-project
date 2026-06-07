output "alb_dns_name" {
  description = "ALB DNS name — set this as the target URL in attack_sim.sh and share with testers"
  value       = aws_lb.main.dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URL — referenced in GitHub Actions to push Docker images"
  value       = aws_ecr_repository.app.repository_url
}

output "app_log_group_name" {
  description = "CloudWatch Log Group that collects Docker container stdout"
  value       = aws_cloudwatch_log_group.app.name
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN — used in the Splunk sourcetype filter and WAF logging config"
  value       = aws_wafv2_web_acl.main.arn
}

output "waf_firehose_stream_name" {
  description = "Kinesis Firehose stream name delivering WAF logs to Splunk"
  value       = aws_kinesis_firehose_delivery_stream.waf_to_splunk.name
}

output "sns_topic_arn" {
  description = "SNS Security Alerts topic — subscribe additional endpoints here if needed"
  value       = aws_sns_topic.security_alerts.arn
}

output "waf_log_s3_bucket" {
  description = "S3 bucket storing WAF log backup (failed Firehose deliveries)"
  value       = aws_s3_bucket.waf_logs.bucket
}

output "waf_blocklist_ip_set_id" {
  description = "WAF IP Set ID for the dynamic blocklist — set as WAF_IP_SET_ID in n8n variables"
  value       = aws_wafv2_ip_set.blocklist.id
}

output "waf_blocklist_ip_set_arn" {
  description = "WAF IP Set ARN for the dynamic blocklist"
  value       = aws_wafv2_ip_set.blocklist.arn
}

output "waf_blocklist_ip_set_name" {
  description = "WAF IP Set name — set as WAF_IP_SET_NAME in n8n variables"
  value       = aws_wafv2_ip_set.blocklist.name
}
