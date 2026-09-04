#!/usr/bin/env bash
# Apply default values for Terraform/Ansible deployment variables.
# Only sets variables that are unset or empty.

# --- General ---
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
OWNER="${OWNER:-ksahu-ygulati}"
ENVIRONMENT="${ENVIRONMENT:-development}"

# --- Terraform resource mode (see build_tf_vars.sh) ---
# When false, EXISTING_* names are used; when true, new resources are created.
CREATE_VPC="${CREATE_VPC:-false}"
CREATE_NEW_SG="${CREATE_NEW_SG:-false}"
CREATE_KEYPAIR="${CREATE_KEYPAIR:-false}"
CREATE_EIP="${CREATE_EIP:-true}"

# --- AWS existing resources (used when create flags above are false) ---
EXISTING_SG_NAME="${EXISTING_SG_NAME:-${ENVIRONMENT}-pvc_cluster_sg}"
EXISTING_KEYPAIR_NAME="${EXISTING_KEYPAIR_NAME:-${ENVIRONMENT}-pvc-session-keypair}"

# --- New VPC settings (only when CREATE_VPC=true) ---
VPC_NAME="${VPC_NAME:-${ENVIRONMENT}-cldr-vpc}"
VPC_CIDR_BLOCK="${VPC_CIDR_BLOCK:-172.16.0.0/16}"
VPC_AZS="${VPC_AZS:-[\"ap-southeast-1a\",\"ap-southeast-1b\"]}"
VPC_PUBLIC_SUBNETS_CIDR="${VPC_PUBLIC_SUBNETS_CIDR:-[\"172.16.0.0/24\"]}"
VPC_PRIVATE_SUBNETS_CIDR="${VPC_PRIVATE_SUBNETS_CIDR:-[]}"
ENABLE_NAT_GATEWAY="${ENABLE_NAT_GATEWAY:-false}"
ENABLE_VPN_GATEWAY="${ENABLE_VPN_GATEWAY:-false}"

# --- New security group (only when CREATE_NEW_SG=true) ---
SG_NAME="${SG_NAME:-${ENVIRONMENT}-pvc_cluster_sg}"
ALLOWED_CIDRS="${ALLOWED_CIDRS:-[\"137.83.231.109/32\", \"137.83.231.11/32\", \"208.127.31.110/32\", \"208.127.31.11/32\", \"139.180.248.227/32\"]}"
ALLOWED_PORTS="${ALLOWED_PORTS:-[0]}"

# --- New keypair (only when CREATE_KEYPAIR=true) ---
KEYPAIR_NAME="${KEYPAIR_NAME:-${ENVIRONMENT}-pvc-new-keypair}"

# --- Elastic IP (when CREATE_EIP=true) ---
CLDR_EIP_NAME="${CLDR_EIP_NAME:-${ENVIRONMENT}-cldr-mngr-eip}"

# --- Cloudera versions (Ansible / group_vars/all.yml — reference only in tfvars) ---
CM_VERSION="${CM_VERSION:-7.13.2.10000}"
# CDH_VERSION="7.3.2.10000"           # base cluster parcel (ansible group_vars)
# ECS_PVC_DS_VERSION="1.5.5-h3300"    # ECS Data Services repo tag (ansible group_vars)

# --- AMI ---
AMI_ID="${AMI_ID:-ami-0a66a47c24c021954}"

# --- Instance group: Cloudera Manager ---
CLDR_MNGR_COUNT="${CLDR_MNGR_COUNT:-1}"
CLDR_MNGR_INSTANCE_TYPE="${CLDR_MNGR_INSTANCE_TYPE:-m5.4xlarge}"
CLDR_MNGR_VOLUME_SIZE="${CLDR_MNGR_VOLUME_SIZE:-300}"

# --- Instance group: FreeIPA / Identity ---
IPA_SERVER_COUNT="${IPA_SERVER_COUNT:-1}"
IPA_SERVER_INSTANCE_TYPE="${IPA_SERVER_INSTANCE_TYPE:-m5.xlarge}"
IPA_SERVER_VOLUME_SIZE="${IPA_SERVER_VOLUME_SIZE:-250}"

# --- Instance group: CDP Base masters ---
PVCBASE_MASTER_COUNT="${PVCBASE_MASTER_COUNT:-1}"
PVCBASE_MASTER_INSTANCE_TYPE="${PVCBASE_MASTER_INSTANCE_TYPE:-m5.4xlarge}"
PVCBASE_MASTER_VOLUME_SIZE="${PVCBASE_MASTER_VOLUME_SIZE:-400}"

# --- Instance group: CDP Base workers ---
PVCBASE_WORKER_COUNT="${PVCBASE_WORKER_COUNT:-3}"
PVCBASE_WORKER_INSTANCE_TYPE="${PVCBASE_WORKER_INSTANCE_TYPE:-m5.4xlarge}"
PVCBASE_WORKER_VOLUME_SIZE="${PVCBASE_WORKER_VOLUME_SIZE:-400}"

# --- Instance group: ECS masters ---
PVCECS_MASTER_COUNT="${PVCECS_MASTER_COUNT:-1}"
PVCECS_MASTER_INSTANCE_TYPE="${PVCECS_MASTER_INSTANCE_TYPE:-m5.8xlarge}"
PVCECS_MASTER_VOLUME_SIZE="${PVCECS_MASTER_VOLUME_SIZE:-1300}"

# --- Instance group: ECS workers ---
PVCECS_WORKER_COUNT="${PVCECS_WORKER_COUNT:-7}"
PVCECS_WORKER_INSTANCE_TYPE="${PVCECS_WORKER_INSTANCE_TYPE:-r5a.4xlarge}"
PVCECS_WORKER_VOLUME_SIZE="${PVCECS_WORKER_VOLUME_SIZE:-1300}"

# --- Tooling (rarely changed) ---
TERRAFORM_VERSION="${TERRAFORM_VERSION:-latest}"

# shellcheck source=scripts/lib/arch_defaults.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/arch_defaults.sh"
