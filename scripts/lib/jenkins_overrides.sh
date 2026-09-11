#!/usr/bin/env bash
# Apply optional Jenkins pipeline UI overrides (non-empty JENKINS_* wins over tfvars).

apply_jenkins_override() {
  local var="$1"
  local jenkins_var="JENKINS_${var}"
  if [[ -n "${!jenkins_var:-}" ]]; then
    export "$var"="${!jenkins_var}"
  fi
}

apply_jenkins_overrides() {
  apply_jenkins_override OWNER
  apply_jenkins_override ENVIRONMENT
  apply_jenkins_override AWS_REGION
  apply_jenkins_override AMI_ID

  apply_jenkins_override CLDR_MNGR_COUNT
  apply_jenkins_override CLDR_MNGR_INSTANCE_TYPE
  apply_jenkins_override CLDR_MNGR_VOLUME_SIZE

  apply_jenkins_override IPA_SERVER_COUNT
  apply_jenkins_override IPA_SERVER_INSTANCE_TYPE
  apply_jenkins_override IPA_SERVER_VOLUME_SIZE

  apply_jenkins_override PVCBASE_MASTER_COUNT
  apply_jenkins_override PVCBASE_MASTER_INSTANCE_TYPE
  apply_jenkins_override PVCBASE_MASTER_VOLUME_SIZE

  apply_jenkins_override PVCBASE_WORKER_COUNT
  apply_jenkins_override PVCBASE_WORKER_INSTANCE_TYPE
  apply_jenkins_override PVCBASE_WORKER_VOLUME_SIZE

  apply_jenkins_override PVCECS_MASTER_COUNT
  apply_jenkins_override PVCECS_MASTER_INSTANCE_TYPE
  apply_jenkins_override PVCECS_MASTER_VOLUME_SIZE

  apply_jenkins_override PVCECS_WORKER_COUNT
  apply_jenkins_override PVCECS_WORKER_INSTANCE_TYPE
  apply_jenkins_override PVCECS_WORKER_VOLUME_SIZE

  apply_jenkins_override VPC_MODE
  apply_jenkins_override SG_MODE
  apply_jenkins_override CREATE_EIP

  apply_jenkins_override VPC_NAME
  apply_jenkins_override VPC_CIDR_BLOCK
  apply_jenkins_override VPC_AZS
  apply_jenkins_override VPC_PUBLIC_SUBNETS_CIDR
  apply_jenkins_override VPC_PRIVATE_SUBNETS_CIDR
  apply_jenkins_override ENABLE_NAT_GATEWAY
  apply_jenkins_override ENABLE_VPN_GATEWAY

  apply_jenkins_override EXISTING_SG_NAME
  apply_jenkins_override SG_NAME
  apply_jenkins_override ALLOWED_CIDRS
  apply_jenkins_override ALLOWED_PORTS
  apply_jenkins_override ALLOW_ALL

  apply_jenkins_override CLDR_EIP_NAME
}
