# This module creates a security group in AWS with the ability to either create a new one or use an existing one.
data "aws_security_group" "existing_sg" {
  count = var.create_new_sg == false ? 1 : 0
  id    = var.existing_sg
}

resource "aws_security_group" "vpc_sg" {
  count       = var.create_new_sg == true ? 1 : 0 # Only create a new security group if the flag is true
  name        = var.sg_name
  description = var.sg_description
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  # Loop only through ports
  dynamic "ingress" {
    for_each = var.allowed_ports
    content {
      description = "Allow traffic on port ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidrs
    }
  }

  # Internal traffic rule
  ingress {
    description = "Allow all internal VPC traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.sg_tags,
    {
      "created_by" = "Terraform"
    }
  )
}
