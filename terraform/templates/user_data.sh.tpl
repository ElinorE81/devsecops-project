#!/bin/bash
# EC2 bootstrap script — runs once on first launch via cloud-init.
# Installs Docker, authenticates to ECR, pulls the app image, and starts
# the container with the CloudWatch awslogs log driver so all stdout lands
# in the pre-created log group without a separate CloudWatch agent process.
set -euo pipefail

# ── System setup ──────────────────────────────────────────────────────────────
yum update -y
amazon-linux-extras install docker -y
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# ── ECR authentication ────────────────────────────────────────────────────────
# Uses the instance IAM role — no stored credentials required.
aws ecr get-login-password --region ${aws_region} \
  | docker login --username AWS --password-stdin ${ecr_repo_url}

# ── Pull latest image ─────────────────────────────────────────────────────────
docker pull ${ecr_repo_url}:latest

# ── Resolve instance ID for the CloudWatch log stream ─────────────────────────
# $INSTANCE_ID uses a bare $ which Terraform's templatefile does not interpret
# (only ${...} patterns are template directives).
INSTANCE_ID=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id)

# ── Run application container ─────────────────────────────────────────────────
docker run -d \
  --name devsecops-app \
  --restart unless-stopped \
  -p 5000:5000 \
  -e GUNICORN_WORKERS=3 \
  --log-driver=awslogs \
  --log-opt awslogs-region=${aws_region} \
  --log-opt awslogs-group=${app_log_group_name} \
  --log-opt awslogs-stream="instance-$INSTANCE_ID" \
  --log-opt awslogs-create-group=false \
  ${ecr_repo_url}:latest
