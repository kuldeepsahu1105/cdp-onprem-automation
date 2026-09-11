#!/usr/bin/env bash
# Reconcile Terraform with existing AWS key pairs / security groups (Jenkins re-runs).

reconcile_is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

reconcile_log() {
  printf '[reconcile] %s\n' "$*"
}

reconcile_default_vpc_id() {
  local region="${AWS_REGION:-ap-southeast-1}"
  aws ec2 describe-vpcs \
    --region "$region" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null | grep -E '^vpc-' || return 1
}

reconcile_aws_keypair_exists() {
  local name="$1" region="${2:-${AWS_REGION:-ap-southeast-1}}"
  aws ec2 describe-key-pairs \
    --region "$region" \
    --key-names "$name" \
    --output text >/dev/null 2>&1
}

reconcile_aws_sg_id_by_name() {
  local name="$1" vpc_id="$2" region="${3:-${AWS_REGION:-ap-southeast-1}}"
  aws ec2 describe-security-groups \
    --region "$region" \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null | grep -E '^sg-' || return 1
}

reconcile_tf_state_has() {
  local addr="$1"
  terraform state show "$addr" >/dev/null 2>&1
}

reconcile_find_pem_for_key() {
  local name="$1" repo_root="${REPO_ROOT:-.}"
  local candidate hol_tf="${HOL_TERRAFORM_STATE_DIR:-}" hol_ans="${HOL_ANSIBLE_STATE_DIR:-}"

  for candidate in \
    "${repo_root}/terraform-code/cloudera-pvc-terraform/${name}.pem" \
    "${repo_root}/ansible-playbooks/${name}.pem" \
    "${repo_root}/ansible-playbooks/sshkey.pem" \
    "${repo_root}/jenkins/artifacts/${name}.pem" \
    "${repo_root}/jenkins/artifacts/sshkey.pem" \
    "${hol_tf:+${hol_tf}/${name}.pem}" \
    "${hol_tf:+${hol_tf}/sshkey.pem}" \
    "${hol_ans:+${hol_ans}/${name}.pem}" \
    "${hol_ans:+${hol_ans}/sshkey.pem}"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

reconcile_keypair() {
  local region="${AWS_REGION:-ap-southeast-1}"
  local tf_dir pem changed=false

  if ! reconcile_is_enabled "${CREATE_KEYPAIR:-false}"; then
    return 0
  fi
  [[ -n "${KEYPAIR_NAME:-}" ]] || return 0

  if ! reconcile_aws_keypair_exists "$KEYPAIR_NAME" "$region"; then
    reconcile_log "Key pair ${KEYPAIR_NAME} not in AWS — will create"
    return 0
  fi

  if reconcile_tf_state_has 'module.key-pair.aws_key_pair.pvc_cluster_keypair[0]'; then
    reconcile_log "Key pair ${KEYPAIR_NAME} already in Terraform state"
    return 0
  fi

  reconcile_log "Key pair ${KEYPAIR_NAME} exists in AWS but not in state — adopting existing key pair"
  export CREATE_KEYPAIR=false
  export EXISTING_KEYPAIR_NAME="$KEYPAIR_NAME"
  changed=true

  tf_dir="${REPO_ROOT:-.}/terraform-code/cloudera-pvc-terraform"
  if pem="$(reconcile_find_pem_for_key "$KEYPAIR_NAME")"; then
    mkdir -p "$tf_dir"
    cp -f "$pem" "${tf_dir}/${KEYPAIR_NAME}.pem"
    chmod 600 "${tf_dir}/${KEYPAIR_NAME}.pem"
    reconcile_log "Restored ${KEYPAIR_NAME}.pem from ${pem}"
  else
    reconcile_log "WARN: ${KEYPAIR_NAME}.pem not found locally — Ansible SSH may fail for new instances"
    reconcile_log "WARN: copy PEM from a previous build artifact or delete the AWS key pair to recreate"
  fi

  [[ "$changed" == true ]] && return 2
  return 0
}

reconcile_security_group() {
  local region="${AWS_REGION:-ap-southeast-1}"
  local vpc_id sg_id

  if ! reconcile_is_enabled "${CREATE_NEW_SG:-false}"; then
    return 0
  fi
  [[ -n "${SG_NAME:-}" ]] || return 0

  if reconcile_tf_state_has 'module.security_group.aws_security_group.vpc_sg[0]'; then
    reconcile_log "Security group ${SG_NAME} already in Terraform state"
    return 0
  fi

  vpc_id="$(reconcile_default_vpc_id)" || {
    reconcile_log "WARN: cannot resolve default VPC for SG reconcile"
    return 0
  }

  sg_id="$(reconcile_aws_sg_id_by_name "$SG_NAME" "$vpc_id" "$region")" || {
    reconcile_log "Security group ${SG_NAME} not in AWS — will create"
    return 0
  }

  reconcile_log "Security group ${SG_NAME} (${sg_id}) exists — importing into Terraform state for in-place rule updates"
  if terraform import -input=false 'module.security_group.aws_security_group.vpc_sg[0]' "$sg_id"; then
    reconcile_log "Imported security group ${sg_id}"
    return 0
  fi

  reconcile_log "WARN: SG import failed — falling back to USE_EXISTING lookup (ingress rules will not be managed)"
  export CREATE_NEW_SG=false
  export EXISTING_SG_NAME="$SG_NAME"
  return 2
}

# Returns 0 = no tfvars change, 2 = CREATE_KEYPAIR/CREATE_NEW_SG flags changed (rebuild TF_VARS)
reconcile_terraform_resources() {
  local rc=0 key_rc sg_rc

  reconcile_keypair
  key_rc=$?
  reconcile_security_group
  sg_rc=$?

  if [[ "$key_rc" == 2 || "$sg_rc" == 2 ]]; then
    return 2
  fi
  return 0
}
