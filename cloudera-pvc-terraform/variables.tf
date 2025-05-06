# Variables for Cloudera PVC Cluster Terraform Module
# This module creates a Cloudera PVC cluster on AWS using Terraform.
# It includes the creation of EC2 instances, VPC, security groups, and other necessary resources.
# The module is designed to be reusable and configurable through input variables.
# The variables are defined below with their descriptions, types, and default values where applicable.
# The module is intended for use in a development environment and can be customized for production use.

# Common Variables
variable "aws_region" {
  description = "AWS region to deploy pvc cluster infra"
  type        = string
  default     = "ap-southeast-1"
}

variable "pvc_cluster_tags" {
  description = "Tags to apply to all EC2 instances"
  type        = map(string)
  default = {
    owner       = "ksahu-ygulati"
    environment = "development"
  }
}

# Keypair Variables
variable "create_keypair" {
  description = "Flag to decide whether to create a new key pair or use an existing one"
  type        = bool
  default     = true
}

variable "keypair_name" {
  description = "Name of the key pair"
  type        = string
}

variable "existing_keypair_name" {
  description = "The name of the existing key pair (if using an existing one)"
  type        = string
  default     = ""
}

# Security Group Variables
variable "sg_name" {
  description = "Name of the security group"
  type        = string
  default     = "pvc_cluster_sg"
}

variable "allowed_ports" {
  description = "List of allowed ports"
  type        = list(number)
  default     = [0]
}

variable "allowed_cidrs" {
  description = "List of CIDR blocks allowed to access the ports"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "create_new_sg" {
  description = "Flag to decide whether to create a new security group or use an existing one"
  type        = bool
  default     = true
}

variable "existing_sg" {
  description = "The name of the existing security group (if using an existing one)"
  type        = string
  default     = ""
}
