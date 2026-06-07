# ── ALB Security Group ────────────────────────────────────────────────────────
# Accepts HTTP from the internet; egress only to EC2 SG.

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB: allow HTTP from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

# ── EC2 Security Group ────────────────────────────────────────────────────────
# Port 5000 only from the ALB SG — EC2 instances are not directly internet-facing.
# Port 22 (SSH) is conditionally opened only when a key pair is provided.

resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "EC2 app servers: accept traffic from ALB only (Least Privilege)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Flask app — from ALB only"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  dynamic "ingress" {
    for_each = var.ec2_key_pair_name != "" ? [1] : []
    content {
      description = "SSH — tighten to your IP in production"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All outbound — required for ECR pull, CloudWatch, SSM, and YUM updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-ec2-sg" }
}
