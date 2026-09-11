#!/usr/bin/env bash
# Use AWS / SSH from holautosa (or CREDENTIALS_USER) home directory.
# Does not modify holautosa files — may stage copies into jenkins/artifacts/ when
# jenkins cannot read /home/holautosa/.aws directly (via sudo -u holautosa cat).

_credentials_is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

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

_resolve_credentials_home() {
  local user="${CREDENTIALS_USER:-holautosa}"
  local home="/home/${user}"

  if [[ ! -d "$home" ]]; then
    printf '[credentials-user] ERROR: home not found: %s\n' "$home" >&2
    return 1
  fi

  export CREDENTIALS_USER="$user"
  export CREDENTIALS_HOME="$home"
  return 0
}

apply_credentials_user_aws() {
  local user home stage_dir creds_dest config_dest

  _resolve_credentials_home || return 1
  user="$CREDENTIALS_USER"
  home="$CREDENTIALS_HOME"
  stage_dir="$(_credentials_stage_dir)"
  creds_dest="${stage_dir}/.holautosa-aws-credentials"
  config_dest="${stage_dir}/.holautosa-aws-config"

  if _credentials_is_enabled "${AWS_USE_INSTANCE_ROLE:-false}"; then
    unset AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
    printf '[credentials-user] AWS_USE_INSTANCE_ROLE=true — skipping %s/.aws\n' "$home"
    return 0
  fi

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
    printf '[credentials-user] Hint: add to sudoers — jenkins ALL=(holautosa) NOPASSWD: ALL\n' >&2
    printf '[credentials-user] Or set AWS_USE_INSTANCE_ROLE=true to use the EC2 IAM role\n' >&2
    return 1
  fi

  # Jenkins AWS_* env overrides credentials file — clear in this shell only.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  return 0
}

apply_credentials_user_ssh() {
  local user home stage_dir key_src key_dest

  _resolve_credentials_home || return 1
  user="$CREDENTIALS_USER"
  home="$CREDENTIALS_HOME"
  stage_dir="$(_credentials_stage_dir)"

  for key_src in "${home}/.ssh/id_rsa" "${home}/.ssh/id_ed25519"; do
    if [[ -r "$key_src" ]]; then
      export ANSIBLE_PRIVATE_KEY="$key_src"
      printf '[credentials-user] ANSIBLE_PRIVATE_KEY=%s (direct read)\n' "$ANSIBLE_PRIVATE_KEY"
      return 0
    fi
    if [[ -f "$key_src" ]]; then
      key_dest="${stage_dir}/.holautosa-ssh-key"
      if _stage_file_via_sudo "$user" "$key_src" "$key_dest"; then
        export ANSIBLE_PRIVATE_KEY="$key_dest"
        printf '[credentials-user] ANSIBLE_PRIVATE_KEY=%s (staged via sudo)\n' "$ANSIBLE_PRIVATE_KEY"
        return 0
      fi
    fi
  done

  printf '[credentials-user] WARN: no SSH key found under %s/.ssh (Ansible may fail)\n' "$home" >&2
  return 0
}

apply_credentials_user() {
  apply_credentials_user_aws || return 1
  apply_credentials_user_ssh
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
      LICENSE_FILE="${LICENSE_FILE:-}" CM_INFO_FILE="${CM_INFO_FILE:-}" \
      CM_REPO_USERNAME="${CM_REPO_USERNAME:-}" CM_REPO_PASSWORD="${CM_REPO_PASSWORD:-}" \
      JENKINS_LICENSE_FILE="${JENKINS_LICENSE_FILE:-}" JENKINS_CM_INFO_FILE="${JENKINS_CM_INFO_FILE:-}" \
      JENKINS_CM_REPO_USERNAME="${JENKINS_CM_REPO_USERNAME:-}" JENKINS_CM_REPO_PASSWORD="${JENKINS_CM_REPO_PASSWORD:-}" \
      TFVARS_FILE="${TFVARS_FILE:-}" DRY_RUN="${DRY_RUN:-}" DEPLOY_PHASE="${DEPLOY_PHASE:-}" \
      PATH="${PATH}" LANG="${LANG:-C.UTF-8}" \
      "$@"
    return $?
  fi

  apply_credentials_user || return 1
  "$@"
}
