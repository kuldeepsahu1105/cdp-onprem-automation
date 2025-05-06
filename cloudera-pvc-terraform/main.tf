# Key Pair Module
module "key-pair" {
  source                = "./modules/key-pair"
  create_keypair        = var.create_keypair
  keypair_name          = var.keypair_name
  existing_keypair_name = var.existing_keypair_name
  keypair_tags          = var.pvc_cluster_tags
}

# Security Group Module
module "security_group" {
  source = "./modules/security-group"
  depends_on = [
    module.vpc
  ]
  sg_name        = var.sg_name
  sg_description = "Allow traffic for the VPC"
  vpc_id         = module.vpc.vpc_id
  allowed_ports  = var.allowed_ports
  allowed_cidrs  = var.allowed_cidrs
  sg_tags        = var.pvc_cluster_tags
  create_new_sg  = var.create_new_sg
  existing_sg    = var.existing_sg
}