#!/usr/bin/env bash
# AWS credential validation — default: holautosa ~/.aws/credentials

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../.." && pwd)"
if [[ -f "${_repo_root}/scripts/lib/output_mode.sh" ]]; then
  # shellcheck source=scripts/lib/output_mode.sh
  source "${_repo_root}/scripts/lib/output_mode.sh"
fi
# shellcheck source=jenkins/scripts/apply-credentials-user.sh
source "${_script_dir}/apply-credentials-user.sh"

is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

aws_cred_log() {
  case "$1" in
    ERROR:*|WARN:*) printf '[aws-creds] %s\n' "$*" >&2 ;;
    *)
      if output_is_quiet 2>/dev/null; then
        return 0
      fi
      printf '[aws-creds] %s\n' "$*"
      ;;
  esac
}

aws_cred_diagnose() {
  output_is_verbose 2>/dev/null || return 0
  apply_credentials_user 2>/dev/null || true
  aws_cred_log "Credential source diagnostics (read-only):"
  aws_cred_log "  CREDENTIALS_USER: ${CREDENTIALS_USER:-holautosa}"
  aws_cred_log "  CREDENTIALS_HOME: ${CREDENTIALS_HOME:-/home/${CREDENTIALS_USER:-holautosa}}"
  aws_cred_log "  AWS_SHARED_CREDENTIALS_FILE: ${AWS_SHARED_CREDENTIALS_FILE:-not set}"
  aws_cred_log "  AWS_CONFIG_FILE: ${AWS_CONFIG_FILE:-not set}"
  if [[ -n "${ANSIBLE_PRIVATE_KEY:-}" && -f "${ANSIBLE_PRIVATE_KEY}" ]]; then
    aws_cred_log "  ANSIBLE_PRIVATE_KEY: ${ANSIBLE_PRIVATE_KEY}"
  fi
  if curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ >/dev/null 2>&1; then
    local role_name
    role_name="$(curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null | head -1 || true)"
    aws_cred_log "  EC2 instance profile (IMDS): available${role_name:+ — role ${role_name}}"
  fi
}

aws_export_instance_role_session() {
  local role creds
  role="$(curl -sf -m 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ | head -1)" || return 1
  [[ -n "$role" ]] || return 1
  creds="$(curl -sf -m 2 "http://169.254.169.254/latest/meta-data/iam/security-credentials/${role}")" || return 1
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(echo "$creds" | jq -r .AccessKeyId)"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | jq -r .SecretAccessKey)"
  AWS_SESSION_TOKEN="$(echo "$creds" | jq -r .Token)"
  [[ -n "$AWS_ACCESS_KEY_ID" && "$AWS_ACCESS_KEY_ID" != "null" ]] || return 1
  aws_cred_log "Loaded EC2 instance role session (role: ${role})"
  return 0
}

aws_apply_instance_role_if_enabled() {
  if is_enabled "${AWS_USE_INSTANCE_ROLE:-false}"; then
    if aws_export_instance_role_session; then
      aws_cred_log "Using EC2 instance role (IMDS)"
      return 0
    fi
    aws_cred_log "WARN: IMDS unavailable — falling back to holautosa ~/.aws"
    export AWS_USE_INSTANCE_ROLE=false
  fi
  apply_credentials_user_aws || return 1
  aws_cred_log "Using holautosa home dir AWS credentials (${AWS_SHARED_CREDENTIALS_FILE:-not set})"
  return 0
}

aws_use_instance_role_only() {
  aws_apply_instance_role_if_enabled
}

aws_verify_caller_identity() {
  local output err

  if is_enabled "${AWS_USE_INSTANCE_ROLE:-false}"; then
    aws_apply_instance_role_if_enabled
    if output="$(aws sts get-caller-identity 2>&1)"; then
      aws_cred_log "OK AWS identity (instance role): $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
      return 0
    fi
    aws_cred_log "ERROR: instance role check failed: $output"
    return 1
  fi

  apply_credentials_user_aws || return 1

  if output="$(aws sts get-caller-identity 2>&1)"; then
    aws_cred_log "OK AWS identity (holautosa ~/.aws): $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
    return 0
  fi
  err="$output"

  # Fallback: verify via sudo when jenkins cannot read holautosa creds directly
  if output="$(run_as_credentials_user aws sts get-caller-identity 2>&1)"; then
    aws_cred_log "OK AWS identity (holautosa via sudo): $(echo "$output" | jq -c '{Account, Arn, UserId}' 2>/dev/null || echo "$output" | head -1)"
    aws_cred_log "WARN: grant jenkins read on /home/holautosa/.aws/credentials to avoid sudo for AWS"
    return 0
  fi
  err="$output"

  aws_cred_log "ERROR: $err"
  aws_cred_log "Hint: ensure /home/holautosa/.aws/credentials exists and jenkins can read it or sudo to holautosa"
  return 1
}
