
# # output "instance_groups" {
# #   description = "Map of instance group to instance group values"
# #   value       = var.instance_groups
# # }

output "instance_ids" {
  value = {
    for k, instance in aws_instance.group_instances :
    k => instance.id
  }
}

output "private_ips" {
  value = {
    for k, instance in aws_instance.group_instances :
    k => instance.private_ip
  }
}

output "public_ips" {
  value = {
    for k, instance in aws_instance.group_instances :
    k => instance.public_ip
  }
}

output "eip_association_id" {
  # value       = aws_eip_association.cldr_mngr["cldr_mngr-1"].id
  value = lookup(aws_eip_association.cldr_mngr, "cldr_mngr-1", null) != null ? lookup(aws_eip_association.cldr_mngr, "cldr_mngr-1", null).id : null
  description = "The Association ID for the EIP and instance"
}

output "ipaserver_ec2_startstop_instance_profile_name" {
  value       = var.ipaserver_ec2_startstop_iam_enabled ? aws_iam_instance_profile.ipaserver_ec2_startstop[0].name : null
  description = "IAM instance profile on ipa_server for EC2 start/stop automation (null when disabled)."
}
