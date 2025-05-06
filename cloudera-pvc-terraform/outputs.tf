# Key Pair Outputs
output "keypair_name" {
  value       = module.key-pair.keypair_name
  description = "The name of the SSH key pair used to access the EC2 instances"
}

# Security Group Outputs
output "sec_group_details" {
  value       = module.security_group.security_group_id
  description = "The security group ID created by the module or the name of the existing security group used"
}
