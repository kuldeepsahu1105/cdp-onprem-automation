#!/usr/bin/env bash
# Jenkins-only overrides applied after tfvars load (BUILD_NUMBER is set in CI).

if [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output_mode.sh" ]]; then
  # shellcheck source=scripts/lib/output_mode.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output_mode.sh"
fi

apply_jenkins_pipeline_defaults() {
  [[ -n "${BUILD_NUMBER:-}" ]] || return 0

  export TF_STATE_BACKEND=local
  export HOL_AUTO_EXEC_DIR="${HOL_AUTO_EXEC_DIR:-/home/${CREDENTIALS_USER:-holautosa}/HOL_AUTO_EXEC_DIR}"

  local kp_suffix="${KEYPAIR_NAME_SUFFIX:-pvc-new-keypair}"
  local sg_suffix="${SG_NAME_SUFFIX:-pvc_cluster_sg}"
  local vpc_mode="${VPC_MODE:-USE_DEFAULT}"
  local sg_mode="${SG_MODE:-USE_EXISTING}"

  # Key pair: always create per environment
  export CREATE_KEYPAIR=true
  export KEYPAIR_NAME="${ENVIRONMENT}-${kp_suffix}"

  # VPC: default = account default VPC; CREATE_NEW = full tfvars VPC block
  case "$vpc_mode" in
    CREATE_NEW)
      export CREATE_VPC=true
      export VPC_NAME="${VPC_NAME:-${ENVIRONMENT}-cldr-vpc}"
      ;;
    USE_DEFAULT|*)
      export CREATE_VPC=false
      ;;
  esac

  # Security group: default = use existing by env prefix; CREATE_NEW = Terraform creates SG
  case "$sg_mode" in
    CREATE_NEW)
      export CREATE_NEW_SG=true
      export SG_NAME="${SG_NAME:-${ENVIRONMENT}-${sg_suffix}}"
      ;;
    USE_EXISTING|*)
      export CREATE_NEW_SG=false
      export EXISTING_SG_NAME="${EXISTING_SG_NAME:-${ENVIRONMENT}-${sg_suffix}}"
      ;;
  esac

  export CLDR_EIP_NAME="${CLDR_EIP_NAME:-${ENVIRONMENT}-cldr-mngr-eip}"

  log_detail "[jenkins-tfvars] VPC_MODE=$vpc_mode CREATE_VPC=$CREATE_VPC SG_MODE=$sg_mode CREATE_NEW_SG=$CREATE_NEW_SG CREATE_KEYPAIR=$CREATE_KEYPAIR"
  log_detail "[jenkins-tfvars] KEYPAIR_NAME=$KEYPAIR_NAME SG(existing=${EXISTING_SG_NAME:-n/a} new=${SG_NAME:-n/a}) VPC=${VPC_NAME:-default}"
}
