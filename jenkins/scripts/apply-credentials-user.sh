#!/usr/bin/env bash
# Point AWS / SSH at an OS user's credential files (default: holautosa).
# Read-only — does not modify or delete any credential files on the agent.

apply_credentials_user() {
  local user="${CREDENTIALS_USER:-holautosa}"
  local home="/home/${user}"

  if [[ ! -d "$home" ]]; then
    printf '[credentials-user] WARN: home not found: %s\n' "$home" >&2
    return 1
  fi

  export CREDENTIALS_USER="$user"
  export CREDENTIALS_HOME="$home"

  if [[ -f "${home}/.aws/credentials" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${home}/.aws/credentials"
    printf '[credentials-user] AWS_SHARED_CREDENTIALS_FILE=%s\n' "$AWS_SHARED_CREDENTIALS_FILE"
  fi
  if [[ -f "${home}/.aws/config" ]]; then
    export AWS_CONFIG_FILE="${home}/.aws/config"
    printf '[credentials-user] AWS_CONFIG_FILE=%s\n' "$AWS_CONFIG_FILE"
  fi

  for key in "${home}/.ssh/id_rsa" "${home}/.ssh/id_ed25519"; do
    if [[ -f "$key" ]]; then
      export ANSIBLE_PRIVATE_KEY="$key"
      printf '[credentials-user] ANSIBLE_PRIVATE_KEY=%s\n' "$ANSIBLE_PRIVATE_KEY"
      break
    fi
  done

  printf '[credentials-user] Using OS user credentials: %s (files unchanged)\n' "$user"
  return 0
}

# Run a command as CREDENTIALS_USER when passwordless sudo is available.
run_as_credentials_user() {
  local user="${CREDENTIALS_USER:-holautosa}"
  if [[ "$(id -un)" == "$user" ]]; then
    "$@"
    return $?
  fi
  if sudo -n -u "$user" -- true 2>/dev/null; then
    sudo -n -u "$user" -- \
      env WORKSPACE="${WORKSPACE:-}" REPO_ROOT="${REPO_ROOT:-}" LOG_DIR="${LOG_DIR:-}" \
      BUILD_NUMBER="${BUILD_NUMBER:-}" CREDENTIALS_USER="$user" CREDENTIALS_HOME="/home/${user}" \
      AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-}" \
      AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-}" \
      ANSIBLE_PRIVATE_KEY="${ANSIBLE_PRIVATE_KEY:-}" \
      PATH="${PATH}" \
      "$@"
    return $?
  fi
  printf '[credentials-user] WARN: cannot sudo to %s — using credential file paths only\n' "$user" >&2
  "$@"
}
