locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # Full HEC URL used by the Lambda forwarder — Firehose uses the base endpoint
  # and appends the path itself; Lambda must supply the full path.
  splunk_hec_events_url = "${var.splunk_hec_endpoint}/services/collector"
}
