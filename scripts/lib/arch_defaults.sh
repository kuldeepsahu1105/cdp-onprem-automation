#!/usr/bin/env bash
# Optional ARM64 / AWS Graviton defaults for deployment configuration.
# Sourced from tfvars_defaults.sh after user overrides are loaded.

# CPU_ARCHITECTURE: x86_64 (default) | arm64
# APPLY_GRAVITON_DEFAULTS: when arm64, remap common x86 instance types to Graviton (*g)
# AUTO_RESOLVE_ARM64_AMI: when arm64 and AMI_ID unset, query latest RHEL 9 arm64 AMI in AWS_REGION
# ECS_DEPLOY_ON_ARM64: allow ECS playbooks on ARM64 (experimental; default false)

CPU_ARCHITECTURE="${CPU_ARCHITECTURE:-x86_64}"
APPLY_GRAVITON_DEFAULTS="${APPLY_GRAVITON_DEFAULTS:-true}"
AUTO_RESOLVE_ARM64_AMI="${AUTO_RESOLVE_ARM64_AMI:-true}"
ECS_DEPLOY_ON_ARM64="${ECS_DEPLOY_ON_ARM64:-false}"

# Default x86_64 AMI placeholder (RHEL 9.7, ap-southeast-1) — replaced when AUTO_RESOLVE_ARM64_AMI runs.
_DEFAULT_X86_AMI="ami-0a66a47c24c021954"

map_instance_type_to_graviton() {
  case "$1" in
    m5.nano) echo m7g.nano ;;
    m5.large) echo m7g.large ;;
    m5.xlarge) echo m7g.xlarge ;;
    m5.2xlarge) echo m7g.2xlarge ;;
    m5.4xlarge) echo m7g.4xlarge ;;
    m5.8xlarge) echo m7g.8xlarge ;;
    m5.12xlarge) echo m7g.12xlarge ;;
    m5.16xlarge) echo m7g.16xlarge ;;
    m5.24xlarge) echo m7g.24xlarge ;;
    r5.large) echo r7g.large ;;
    r5.xlarge) echo r7g.xlarge ;;
    r5.2xlarge) echo r7g.2xlarge ;;
    r5.4xlarge) echo r7g.4xlarge ;;
    r5.8xlarge) echo r7g.8xlarge ;;
    r5a.large) echo r7g.large ;;
    r5a.xlarge) echo r7g.xlarge ;;
    r5a.2xlarge) echo r7g.2xlarge ;;
    r5a.4xlarge) echo r7g.4xlarge ;;
    r5a.8xlarge) echo r7g.8xlarge ;;
    t3.nano) echo t4g.nano ;;
    t3.micro) echo t4g.micro ;;
    t3.small) echo t4g.small ;;
    t3.medium) echo t4g.medium ;;
    t3.large) echo t4g.large ;;
    t3.xlarge) echo t4g.xlarge ;;
    t3.2xlarge) echo t4g.2xlarge ;;
    *)
      if [[ "$1" =~ ^m6i\. ]]; then
        echo "${1/m6i./m7g.}"
      elif [[ "$1" =~ ^r6i\. ]]; then
        echo "${1/r6i./r7g.}"
      elif [[ "$1" =~ ^c5\. ]]; then
        echo "${1/c5./c7g.}"
      else
        printf '%s' "$1"
      fi
      ;;
  esac
}

remap_var_to_graviton() {
  local var_name="$1"
  local current="${!var_name}"
  local mapped
  mapped="$(map_instance_type_to_graviton "$current")"
  if [[ "$mapped" != "$current" ]]; then
    printf -v "$var_name" '%s' "$mapped"
  fi
}

resolve_arm64_ami() {
  if [[ "${CPU_ARCHITECTURE}" != "arm64" ]]; then
    return 0
  fi
  if [[ "${AUTO_RESOLVE_ARM64_AMI}" != "true" ]]; then
    return 0
  fi
  if [[ -n "${AMI_ID:-}" && "${AMI_ID}" != "${_DEFAULT_X86_AMI}" ]]; then
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    echo "Warning: CPU_ARCHITECTURE=arm64 but aws CLI not available to resolve ARM64 AMI. Set AMI_ID manually." >&2
    return 0
  fi

  local resolved=""
  resolved="$(aws ec2 describe-images \
    --region "${AWS_REGION}" \
    --owners 309956199498 \
    --filters \
      "Name=name,Values=RHEL-9.*_HVM-*-arm64-*" \
      "Name=state,Values=available" \
      "Name=architecture,Values=arm64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text 2>/dev/null || true)"

  if [[ -n "$resolved" && "$resolved" != "None" ]]; then
    AMI_ID="$resolved"
    export AMI_ID
  else
    echo "Warning: Could not auto-resolve RHEL 9 arm64 AMI in ${AWS_REGION}. Set AMI_ID in .tfvars." >&2
  fi
}

apply_arm64_defaults() {
  if [[ "${CPU_ARCHITECTURE}" != "arm64" ]]; then
    return 0
  fi

  resolve_arm64_ami

  if [[ "${APPLY_GRAVITON_DEFAULTS}" == "true" ]]; then
    remap_var_to_graviton CLDR_MNGR_INSTANCE_TYPE
    remap_var_to_graviton IPA_SERVER_INSTANCE_TYPE
    remap_var_to_graviton PVCBASE_MASTER_INSTANCE_TYPE
    remap_var_to_graviton PVCBASE_WORKER_INSTANCE_TYPE
    remap_var_to_graviton PVCECS_MASTER_INSTANCE_TYPE
    remap_var_to_graviton PVCECS_WORKER_INSTANCE_TYPE
  fi

  if [[ "${ECS_DEPLOY_ON_ARM64}" != "true" ]]; then
    if [[ "${PVCECS_MASTER_COUNT:-1}" != "0" || "${PVCECS_WORKER_COUNT:-7}" != "0" ]]; then
      echo "Note: CPU_ARCHITECTURE=arm64 — ECS instance counts set to 0 (set ECS_DEPLOY_ON_ARM64=true to enable)." >&2
    fi
    PVCECS_MASTER_COUNT=0
    PVCECS_WORKER_COUNT=0
    export PVCECS_MASTER_COUNT PVCECS_WORKER_COUNT
  fi

  export CPU_ARCHITECTURE APPLY_GRAVITON_DEFAULTS AUTO_RESOLVE_ARM64_AMI ECS_DEPLOY_ON_ARM64
}

apply_arm64_defaults
