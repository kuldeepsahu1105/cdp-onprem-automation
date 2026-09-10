#!/usr/bin/env bash
# AWS credential helpers for Jenkins on EC2.
# Uses holautosa (or CREDENTIALS_USER) ~/.aws by default; optional IMDS instance role.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=jenkins/scripts/apply-credentials-user.sh
source "${_script_dir}/apply-credentials-user.sh"

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
  apply_credentials_user 2>/dev/null || true
  aws_cred_log "Credential source diagnostics (read-only):"
  aws_cred_log "  CREDENTIALS_USER: ${CREDENTIALS_USER:-holautosa}"
  aws_cred_log "  CREDENTIALS_HOME: ${CREDENTIALS_HOME:-/home/${CREDENTIALS_USER:-holautosa}}"
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    aws_cred_log "  AWS_ACCESS_KEY_ID: set (${#AWS_ACCESS_KEY_ID} chars)"
  else
    aws_cred_log "  AWS_ACCESS_KEY_ID: unset"
  fi
  aws_cred_log "  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:+set}${AWS_SECRET_ACCESS_KEY:-unset}"
  aws_cred_log "  AWS_SESSION_TOKEN: ${AWS_SESSION_TOKEN:+set}${AWS_SESSION_TOKEN:-unset}"
  aws_cred_log "  AWS_PROFILE: ${AWS_PROFILE:-unset}"
  aws_cred_log "  AWS_SHARED_CREDENTIALS_FILE: ${AWS_SHARED_CREDENTIALS_FILE:-not set}"
  if [[ -n "${AWS_SHARED_CREDENTIALS_FILE:-}" && -f "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
    aws_cred_log "  credentials file: present"
  fi
  if [[ -n "${ANSIBLE_PRIVATE_KEY:-}" && -f "${ANSIBLE_PRIVATE_KEY}" ]]; then
    aws_cred_log "  ANSIBLE_PRIVATE_KEY: ${ANSIBLE_PRIVATE_KEY}"
  fi
  if curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ >/dev/null 2>&1; then
    local role_name
    role_name="$(curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null | head -1 || true)"
    aws_cred_log "  EC2 instance profile (IMDS): available${role_name:+ — role ${role_name}}"
  else
    aws_cred_log "  EC2 instance profile (IMDS): not detected on this host"
  fi
}

# Fetch temporary credentials from the EC2 instance IAM role (IMDS).
# Exports session env vars for this shell only — no files removed or changed.
aws_export_instance_role_session() {
  local role creds
  role="$(curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ | head -1)" || return 1
  [[ -n "$role" ]] || return 1
  creds="$(curl -sf -m 2 "http://169.254.169.254/latest/meta-data/iam/security-credentials/${role}")" || return 1
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(echo "$creds" | jq -r .AccessKeyId)"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | jq -r .SecretAccessKey)"
  AWS_SESSION_TOKEN="$(echo "$creds" | jq -r .Token)"
  [[ -n "$AWS_ACCESS_KEY_ID" && "$AWS_ACCESS_KEY_ID" != "null" ]] || return 1
  aws_cred_log "Loaded EC2 instance role session for this pipeline step (role: ${role}; agent credential files unchanged)"
  return 0
}

# When enabled, prefer instance-role session for this step (overrides bad env in-process only).
aws_apply_instance_role_if_enabled() {
  if ! is_enabled "${AWS_USE_INSTANCE_ROLE:-false}"; then
    aws_cred_log "AWS_USE_INSTANCE_ROLE=false — using ${CREDENTIALS_USER:-holautosa} / agent AWS credentials"
    apply_credentials_user 2>/dev/null || true
    return 0
  fi
  if aws_export_instance_role_session; then
    return 0
  fi
  aws_cred_log "WARN: AWS_USE_INSTANCE_ROLE=true but IMDS session unavailable — using agent/Jenkins credentials"
  return 0
}

# Backward compatibility for Jenkinsfiles that still call the old function name.
aws_use_instance_role_only() {
  aws_cred_log "NOTE: aws_use_instance_role_only is deprecated — use aws_apply_instance_role_if_enabled"
  aws_apply_instance_role_if_enabled
}

aws_verify_caller_identity() {
  local output err tried_imds=false

  apply_credentials_user 2>/dev/null || true

  if is_enabled "${AWS_USE_INSTANCE_ROLE:-false}"; then
    tried_imds=true
    aws_apply_instance_role_if_enabled
  fi

  if output="$(aws sts get-caller-identity 2>&1)"; then
    aws_cred_log "OK AWS identity: $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
    return 0
  fi
  err="$output"

  if ! $tried_imds && is_enabled "${AWS_USE_INSTANCE_ROLE:-false}"; then
    if echo "$err" | grep -qiE 'InvalidClientTokenId|ExpiredToken|SignatureDoesNotMatch|UnrecognizedClientException'; then
      aws_cred_log "WARN: configured credentials failed — trying EC2 instance role session (agent files unchanged)"
      if aws_export_instance_role_session && output="$(aws sts get-caller-identity 2>&1)"; then
        aws_cred_log "OK AWS identity (instance role): $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
        return 0
      fi
      err="$output"
    fi
  fi

  aws_cred_log "ERROR: $err"
  aws_cred_log "Hint: set CREDENTIALS_USER=holautosa (default) or enable AWS_USE_INSTANCE_ROLE on EC2."
  aws_cred_log "Hint: this pipeline never deletes or modifies credential files on the agent."
  return 1
}
