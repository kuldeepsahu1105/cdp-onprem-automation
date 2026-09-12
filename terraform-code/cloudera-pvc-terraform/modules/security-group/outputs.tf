# Outputs for the security group module
locals {
  existing_security_group_id = local.use_existing_sg_by_id ? data.aws_security_group.existing_sg_by_id[0].id : (
    local.use_existing_sg_by_name ? data.aws_security_group.existing_sg_by_name[0].id : null
  )
}

output "security_group_id" {
  description = "ID of the security group (new or existing)"
  value       = var.create_new_sg ? aws_security_group.vpc_sg[0].id : local.existing_security_group_id
}
