# IAM instance profile on ipaserver so /root/{prefix}_cldr_ec2_strt_stp.sh can call EC2 APIs via IMDS.
# Tag scope matches the shell script filters: tag:environment + tag:Group (Terraform instance_groups keys).

locals {
  ipaserver_startstop_environment = lookup(var.pvc_cluster_tags, "environment", "development")
  ipaserver_startstop_group_keys  = keys(var.instance_groups)
  ipaserver_startstop_name_suffix = substr(
    replace(replace(local.ipaserver_startstop_environment, "_", "-"), ".", "-"),
    0,
    40
  )
  ipaserver_startstop_iam_base_name = "${local.ipaserver_startstop_name_suffix}-ipaserver-ec2-ss"
}

resource "aws_iam_role" "ipaserver_ec2_startstop" {
  count = var.ipaserver_ec2_startstop_iam_enabled ? 1 : 0

  name = local.ipaserver_startstop_iam_base_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.pvc_cluster_tags, {
    Name = local.ipaserver_startstop_iam_base_name
  })
}

resource "aws_iam_role_policy" "ipaserver_ec2_startstop" {
  count = var.ipaserver_ec2_startstop_iam_enabled ? 1 : 0

  name = "${local.ipaserver_startstop_iam_base_name}-policy"
  role = aws_iam_role.ipaserver_ec2_startstop[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeInstancesForStartStopWorkflow"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus"
        ]
        Resource = "*"
      },
      {
        Sid    = "StartStopInstancesByEnvironmentAndGroupTags"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/environment" = local.ipaserver_startstop_environment
          }
          "ForAnyValue:StringEquals" = {
            "ec2:ResourceTag/Group" = local.ipaserver_startstop_group_keys
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ipaserver_ec2_startstop" {
  count = var.ipaserver_ec2_startstop_iam_enabled ? 1 : 0

  name = local.ipaserver_startstop_iam_base_name
  role = aws_iam_role.ipaserver_ec2_startstop[0].name

  tags = merge(var.pvc_cluster_tags, {
    Name = local.ipaserver_startstop_iam_base_name
  })
}
