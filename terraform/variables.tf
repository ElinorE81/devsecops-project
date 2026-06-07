# ── Core ─────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short identifier used as a prefix in every resource name"
  type        = string
  default     = "devsecops"
}

variable "environment" {
  description = "Deployment environment tag (prod / staging / dev)"
  type        = string
  default     = "prod"
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the project VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets — one per AZ, required by ALB"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

# ── EC2 / ASG ─────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "EC2 instance type for application servers"
  type        = string
  default     = "t2.micro"
}

variable "ec2_key_pair_name" {
  description = "Name of an existing EC2 Key Pair for SSH access — leave empty to disable SSH ingress"
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances in the Auto Scaling Group"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances in the Auto Scaling Group"
  type        = number
  default     = 3
}

variable "asg_desired_capacity" {
  description = "Desired number of EC2 instances at steady state"
  type        = number
  default     = 1
}

# ── WAF ───────────────────────────────────────────────────────────────────────

variable "waf_rate_limit" {
  description = "Maximum requests per 5-minute window from a single IP before WAF blocks it"
  type        = number
  default     = 1000
}

# ── CloudWatch / Alerting ─────────────────────────────────────────────────────

variable "alarm_blocked_requests_threshold" {
  description = "WAF BlockedRequests count per 1-minute period that triggers the CloudWatch Alarm"
  type        = number
  default     = 50
}

variable "alarm_email" {
  description = "Admin email address for SNS security alert notifications (leave empty to skip)"
  type        = string
  default     = ""
}

variable "n8n_webhook_url" {
  description = "Public HTTPS URL of the n8n webhook node — e.g. https://<ngrok-id>.ngrok.io/webhook/<id>"
  type        = string
  default     = ""
}

# ── Splunk HEC ────────────────────────────────────────────────────────────────
# Fill in terraform.tfvars (never commit real values).
# Use the TF_VAR_splunk_hec_token environment variable for the token.

variable "splunk_hec_endpoint" {
  description = <<-EOT
    Base Splunk HEC endpoint — host and port only, no path.
    Kinesis Firehose appends the HEC path automatically.
    Local Docker via ngrok example : https://abc123.ngrok.io
    Splunk Cloud example           : https://input-prd-p-xxxxx.cloud.splunk.com:8088
  EOT
  type        = string
  default     = "PLACEHOLDER_SPLUNK_HEC_ENDPOINT"
}

variable "splunk_hec_token" {
  description = "Splunk HEC authentication token — treat as a secret"
  type        = string
  sensitive   = true
  default     = "PLACEHOLDER_SPLUNK_HEC_TOKEN"
}

variable "splunk_index" {
  description = "Target Splunk index for all project security events"
  type        = string
  default     = "devsecops_security"
}
