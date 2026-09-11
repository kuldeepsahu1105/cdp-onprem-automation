#!/usr/bin/env bash
# Use AWS / SSH from holautosa (or CREDENTIALS_USER) home directory.
# Does not modify holautosa files — may stage copies into jenkins/artifacts/ when
# jenkins cannot read /home/holautosa/.aws directly (via sudo -u holautosa cat).

_credentials_stage_dir() {
  local root="${REPO_ROOT:-${WORKSPACE:-.}}"
  printf '%s/jenkins/artifacts' "$root"
}

_stage_file_via_sudo() {
  local user="$1" src="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  if [[ -r "$src" ]]; then
    cp "$src" "$dest"
  elif sudo -n -u "$user" -- test -r "$src" 2>/dev/null; then
    sudo -n -u "$user" -- cat "$src" > "$dest"
  else
    return 1
  fi
  chmod 600 "$dest"
  return 0
}

apply_credentials_user() {
  local user="${CREDENTIALS_USER:-holautosa}"
  local home="/home/${user}"
  local stage_dir creds_dest config_dest key_src

  if [[ ! -d "$home" ]]; then
    printf '[credentials-user] ERROR: home not found: %s\n' "$home" >&2
    return 1
  fi

  export CREDENTIALS_USER="$user"
  export CREDENTIALS_HOME="$home"
  stage_dir="$(_credentials_stage_dir)"
  creds_dest="${stage_dir}/.holautosa-aws-credentials"
  config_dest="${stage_dir}/.holautosa-aws-config"

  if [[ -r "${home}/.aws/credentials" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${home}/.aws/credentials"
    printf '[credentials-user] AWS_SHARED_CREDENTIALS_FILE=%s (direct read)\n' "$AWS_SHARED_CREDENTIALS_FILE"
    if [[ -r "${home}/.aws/config" ]]; then
      export AWS_CONFIG_FILE="${home}/.aws/config"
      printf '[credentials-user] AWS_CONFIG_FILE=%s (direct read)\n' "$AWS_CONFIG_FILE"
    fi
  elif _stage_file_via_sudo "$user" "${home}/.aws/credentials" "$creds_dest"; then
    export AWS_SHARED_CREDENTIALS_FILE="$creds_dest"
    export CREDENTIALS_STAGED=true
    printf '[credentials-user] AWS_SHARED_CREDENTIALS_FILE=%s (staged via sudo from %s)\n' "$creds_dest" "$user"
    if [[ -f "${home}/.aws/config" ]] && _stage_file_via_sudo "$user" "${home}/.aws/config" "$config_dest"; then
      export AWS_CONFIG_FILE="$config_dest"
      printf '[credentials-user] AWS_CONFIG_FILE=%s (staged via sudo)\n' "$config_dest"
    fi
  else
    printf '[credentials-user] ERROR: cannot read %s/.aws/credentials as %s and sudo to %s failed\n' "$home" "$(id -un)" "$user" >&2
    printf '[credentials-user] Hint: jenkins ALL=(holautosa) NOPASSWD: ALL in sudoers\n' >&2
    return 1
  fi

  # Jenkins AWS_* env overrides credentials file — clear in this shell only.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_PROFILE AWS_DEFAULT_PROFILE

  for key_src in "${home}/.ssh/id_rsa" "${home}/.ssh/id_ed25519"; do
    if [[ -r "$key_src" ]]; then
      export ANSIBLE_PRIVATE_KEY="$key_src"
      printf '[credentials-user] ANSIBLE_PRIVATE_KEY=%s (direct read)\n' "$ANSIBLE_PRIVATE_KEY"
      break
    fi
    if [[ -f "$key_src" ]]; then
      local key_dest="${stage_dir}/.holautosa-ssh-key"
      if _stage_file_via_sudo "$user" "$key_src" "$key_dest"; then
        export ANSIBLE_PRIVATE_KEY="$key_dest"
        printf '[credentials-user] ANSIBLE_PRIVATE_KEY=%s (staged via sudo)\n' "$ANSIBLE_PRIVATE_KEY"
        break
      fi
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
      AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-${home}/.aws/credentials}" \
      AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${home}/.aws/config}" \
      ANSIBLE_PRIVATE_KEY="${ANSIBLE_PRIVATE_KEY:-}" \
      TFVARS_FILE="${TFVARS_FILE:-}" DRY_RUN="${DRY_RUN:-}" DEPLOY_PHASE="${DEPLOY_PHASE:-}" \
      PATH="${PATH}" LANG="${LANG:-C.UTF-8}" \
      "$@"
    return $?
  fi

  apply_credentials_user || return 1
  "$@"
}
