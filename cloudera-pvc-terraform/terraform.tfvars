aws_region = "ap-southeast-1"

pvc_cluster_tags = {
  owner       = "ksahu"
  environment = "development"
}

# VPC

# Security Group
create_new_sg = true # Will be set to true if create_vpc is true, if cre ate_vpc is false, it can be set to true/false
allowed_cidrs = ["0.0.0.0/0"]
allowed_ports = [0]
sg_name       = "pvc_cluster_sg"
existing_sg   = "sg-0dbb6f79cba5ef701" # Existing security group ID

# Elastic IP

# Keypair
create_keypair        = true
keypair_name          = "pvc-new-keypair"
existing_keypair_name = "kuldeep-pvc-session"
