#!/usr/bin/env bash
# Use AWS / SSH from holautosa (or CREDENTIALS_USER) home directory.
# Read-only — does not modify or delete credential files on the agent.

apply_credentials_user() {
  local user="${CREDENTIALS_USER:-holautosa}"
  local home="/home/${user}"

  if [[ ! -d "$home" ]]; then
    printf '[credentials-user] ERROR: home not found: %s\n' "$home" >&2
    return 1
  fi

  export CREDENTIALS_USER="$user"
  export CREDENTIALS_HOME="$home"

  if [[ ! -f "${home}/.aws/credentials" ]]; then
    printf '[credentials-user] ERROR: missing %s/.aws/credentials\n' "$home" >&2
    return 1
  fi

  export AWS_SHARED_CREDENTIALS_FILE="${home}/.aws/credentials"
  export AWS_CONFIG_FILE="${home}/.aws/config"
  printf '[credentials-user] AWS_SHARED_CREDENTIALS_FILE=%s\n' "$AWS_SHARED_CREDENTIALS_FILE"
  if [[ -f "${home}/.aws/config" ]]; then
    printf '[credentials-user] AWS_CONFIG_FILE=%s\n' "$AWS_CONFIG_FILE"
  fi

  # Jenkins/AWS_* env vars take precedence over credentials file — clear in this shell only.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  printf '[credentials-user] Using AWS credentials from %s/.aws/ (in-process AWS_* env cleared; files unchanged)\n' "$user"

  for key in "${home}/.ssh/id_rsa" "${home}/.ssh/id_ed25519"; do
    if [[ -f "$key" ]]; then
      export ANSIBLE_PRIVATE_KEY="$key"
      printf '[credentials-user] ANSIBLE_PRIVATE_KEY=%s\n' "$ANSIBLE_PRIVATE_KEY"
      break
    fi
  done

  return 0
}

# Run a command as CREDENTIALS_USER when passwordless sudo is available.
run_as_credentials_user() {
  local user="${CREDENTIALS_USER:-holautosa}"
  local home="/home/${user}"

  if [[ "$(id -un)" == "$user" ]]; then
    apply_credentials_user || return 1
    "$@"
    return $?
  fi

  if sudo -n -u "$user" -- true 2>/dev/null; then
    sudo -n -u "$user" -- \
      env HOME="$home" \
      WORKSPACE="${WORKSPACE:-}" REPO_ROOT="${REPO_ROOT:-}" LOG_DIR="${LOG_DIR:-}" \
      BUILD_NUMBER="${BUILD_NUMBER:-}" \
      CREDENTIALS_USER="$user" CREDENTIALS_HOME="$home" \
      AWS_SHARED_CREDENTIALS_FILE="${home}/.aws/credentials" \
      AWS_CONFIG_FILE="${home}/.aws/config" \
      ANSIBLE_PRIVATE_KEY="${ANSIBLE_PRIVATE_KEY:-}" \
      TFVARS_FILE="${TFVARS_FILE:-}" DRY_RUN="${DRY_RUN:-}" DEPLOY_PHASE="${DEPLOY_PHASE:-}" \
      PATH="${PATH}" LANG="${LANG:-C.UTF-8}" \
      "$@"
    return $?
  fi

  printf '[credentials-user] WARN: passwordless sudo to %s not available — using %s/.aws via env only\n' "$user" "$user" >&2
  apply_credentials_user || return 1
  "$@"
}
