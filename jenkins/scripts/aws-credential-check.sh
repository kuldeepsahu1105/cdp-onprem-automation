#!/usr/bin/env bash
# AWS credential validation with EC2 instance-role support.
# Static env vars or ~/.aws/credentials override the instance IAM role and often
# cause InvalidClientTokenId even when the EC2 instance has a valid role attached.

is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

aws_cred_log() {
  printf '[aws-creds] %s\n' "$*"
}

aws_cred_diagnose() {
  aws_cred_log "Credential source diagnostics:"
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    aws_cred_log "  AWS_ACCESS_KEY_ID: set (${#AWS_ACCESS_KEY_ID} chars)"
  else
    aws_cred_log "  AWS_ACCESS_KEY_ID: unset"
  fi
  aws_cred_log "  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:+set}${AWS_SECRET_ACCESS_KEY:-unset}"
  aws_cred_log "  AWS_SESSION_TOKEN: ${AWS_SESSION_TOKEN:+set}${AWS_SESSION_TOKEN:-unset}"
  aws_cred_log "  AWS_PROFILE: ${AWS_PROFILE:-unset}"
  aws_cred_log "  AWS_SHARED_CREDENTIALS_FILE: ${AWS_SHARED_CREDENTIALS_FILE:-default ~/.aws/credentials}"
  if [[ -f "${HOME}/.aws/credentials" ]]; then
    aws_cred_log "  ~/.aws/credentials: present (may override instance role if keys are invalid)"
  else
    aws_cred_log "  ~/.aws/credentials: not found"
  fi
  if curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ >/dev/null 2>&1; then
    local role_name
    role_name="$(curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null | head -1 || true)"
    aws_cred_log "  EC2 instance profile (IMDS): available${role_name:+ — role ${role_name}}"
  else
    aws_cred_log "  EC2 instance profile (IMDS): not detected on this host"
  fi
}

# Bypass static keys and shared credentials file so the EC2 instance role is used.
aws_use_instance_role_only() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  local empty_creds
  empty_creds="${TMPDIR:-/tmp}/jenkins-empty-aws-credentials"
  : > "$empty_creds"
  export AWS_SHARED_CREDENTIALS_FILE="$empty_creds"
  export AWS_EC2_METADATA_DISABLED=false
  aws_cred_log "Using EC2 instance role only (cleared static AWS env and shared credentials file)"
}

aws_verify_caller_identity() {
  local output err
  if output="$(aws sts get-caller-identity 2>&1)"; then
    aws_cred_log "OK AWS identity: $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
    return 0
  fi
  err="$output"

  if echo "$err" | grep -qiE 'InvalidClientTokenId|ExpiredToken|SignatureDoesNotMatch|UnrecognizedClientException'; then
    if is_enabled "${AWS_USE_INSTANCE_ROLE:-true}"; then
      aws_cred_log "WARN: AWS call failed with invalid/expired static credentials — retrying via instance role"
      aws_use_instance_role_only
      if output="$(aws sts get-caller-identity 2>&1)"; then
        aws_cred_log "OK AWS identity (instance role): $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
        return 0
      fi
      err="$output"
    fi
  fi

  aws_cred_log "ERROR: $err"
  aws_cred_log "Hint: remove expired Jenkins 'AWS Credentials' bindings / AWS_* global env vars."
  aws_cred_log "Hint: set pipeline parameter AWS_USE_INSTANCE_ROLE=true (default) on EC2 agents with IAM role."
  aws_cred_log "Hint: on agent run: unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; aws sts get-caller-identity"
  return 1
}
