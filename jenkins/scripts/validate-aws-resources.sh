#!/usr/bin/env bash
# Pre-Terraform checks: existing key pair and security group in AWS.
set -euo pipefail

is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_aws_resources() {
  local region="${AWS_REGION:-ap-southeast-1}"
  local vpc_id

  if ! is_enabled "${REQUIRE_TERRAFORM:-false}"; then
    return 0
  fi

  if is_enabled "${CREATE_KEYPAIR:-false}"; then
    printf '[validate-aws] Skipping key pair check (create_keypair=true)\n'
  else
    [[ -n "${EXISTING_KEYPAIR_NAME:-}" ]] || {
      printf '[validate-aws] ERROR: EXISTING_KEYPAIR_NAME is empty and create_keypair=false\n' >&2
      return 1
    }
    if ! aws ec2 describe-key-pairs \
      --region "$region" \
      --key-names "${EXISTING_KEYPAIR_NAME}" \
      --output text >/dev/null 2>&1; then
      printf '[validate-aws] ERROR: EC2 key pair not found in %s: %s\n' "$region" "${EXISTING_KEYPAIR_NAME}" >&2
      printf '[validate-aws] Hint: set create_keypair=true in tfvars or fix existing_keypair_name\n' >&2
      return 1
    fi
    printf '[validate-aws] OK key pair: %s (%s)\n' "${EXISTING_KEYPAIR_NAME}" "$region"
  fi

  if is_enabled "${CREATE_NEW_SG:-false}"; then
    printf '[validate-aws] Skipping security group check (create_new_sg=true)\n'
    return 0
  fi

  [[ -n "${EXISTING_SG_NAME:-}" ]] || {
    printf '[validate-aws] ERROR: EXISTING_SG_NAME is empty and create_new_sg=false\n' >&2
    return 1
  }

  if [[ "${EXISTING_SG_NAME}" =~ ^sg- ]]; then
    if ! aws ec2 describe-security-groups \
      --region "$region" \
      --group-ids "${EXISTING_SG_NAME}" \
      --output text >/dev/null 2>&1; then
      printf '[validate-aws] ERROR: security group ID not found in %s: %s\n' "$region" "${EXISTING_SG_NAME}" >&2
      return 1
    fi
    printf '[validate-aws] OK security group ID: %s (%s)\n' "${EXISTING_SG_NAME}" "$region"
    return 0
  fi

  if is_enabled "${CREATE_VPC:-false}"; then
    printf '[validate-aws] WARN: cannot verify SG name %s without deployed VPC — Terraform will resolve by name\n' "${EXISTING_SG_NAME}"
    return 0
  fi

  vpc_id="$(aws ec2 describe-vpcs \
    --region "$region" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || true)"
  [[ -n "$vpc_id" && "$vpc_id" != "None" ]] || {
    printf '[validate-aws] WARN: default VPC not found — skipping SG name check for %s\n' "${EXISTING_SG_NAME}"
    return 0
  }

  if ! aws ec2 describe-security-groups \
    --region "$region" \
    --filters "Name=group-name,Values=${EXISTING_SG_NAME}" "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null | grep -q '^sg-'; then
    printf '[validate-aws] ERROR: security group name not found in %s VPC %s: %s\n' "$region" "$vpc_id" "${EXISTING_SG_NAME}" >&2
    printf '[validate-aws] Hint: use sg-xxxxxxxx ID or set create_new_sg=true\n' >&2
    return 1
  fi
  printf '[validate-aws] OK security group name: %s (vpc=%s, region=%s)\n' "${EXISTING_SG_NAME}" "$vpc_id" "$region"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  validate_aws_resources
fi
