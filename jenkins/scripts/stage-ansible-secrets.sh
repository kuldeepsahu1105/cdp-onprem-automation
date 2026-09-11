#!/usr/bin/env bash
# Stage Cloudera license and CM archive credentials for Ansible (phases 3+).
# Sources: Jenkins parameters / env vars, Jenkins credentials (via exported env),
# or pre-placed files under ansible-playbooks/.
set -euo pipefail

_stage_secrets_repo_root() {
  printf '%s' "${REPO_ROOT:-${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
}

_stage_secrets_log() {
  printf '[stage-secrets] %s\n' "$*"
}

# Resolve LICENSE_FILE / CM_INFO_FILE from Jenkins-prefixed or direct env vars.
_stage_secrets_resolve_inputs() {
  LICENSE_FILE="${LICENSE_FILE:-${JENKINS_LICENSE_FILE:-}}"
  CM_INFO_FILE="${CM_INFO_FILE:-${JENKINS_CM_INFO_FILE:-}}"
  CM_REPO_USERNAME="${CM_REPO_USERNAME:-${JENKINS_CM_REPO_USERNAME:-}}"
  CM_REPO_PASSWORD="${CM_REPO_PASSWORD:-${JENKINS_CM_REPO_PASSWORD:-}}"
  export LICENSE_FILE CM_INFO_FILE CM_REPO_USERNAME CM_REPO_PASSWORD
}

# Reject path traversal; allow workspace-relative or absolute paths on the agent.
_stage_secrets_validate_path() {
  local label="$1"
  local path="$2"
  local root="$3"

  if [[ -z "$path" ]]; then
    return 0
  fi

  if [[ "$path" == *".."* ]]; then
    _stage_secrets_log "ERROR: ${label} must not contain '..': ${path}"
    return 1
  fi

  if [[ "$path" != /* ]]; then
    path="${root}/${path#./}"
  fi

  if [[ ! -f "$path" ]]; then
    _stage_secrets_log "ERROR: ${label} not found: ${path}"
    return 1
  fi

  printf '%s' "$path"
}

_stage_secrets_copy_into_ansible() {
  local src="$1"
  local dest_dir="$2"
  local dest_name="$3"
  local dest="${dest_dir}/${dest_name}"

  mkdir -p "$dest_dir"
  cp -f "$src" "$dest"
  chmod 600 "$dest"
  printf '%s' "$dest"
}

# Copy license / info files into ansible-playbooks/ and export absolute paths.
stage_ansible_secrets() {
  local repo_root ansible_dir phase
  repo_root="$(_stage_secrets_repo_root)"
  ansible_dir="${repo_root}/ansible-playbooks"
  phase="${DEPLOY_PHASE:-1}"

  _stage_secrets_resolve_inputs

  if [[ -n "${LICENSE_FILE:-}" ]]; then
    local license_src license_dest
    license_src="$(_stage_secrets_validate_path "LICENSE_FILE" "$LICENSE_FILE" "$repo_root")" || return 1
    license_dest="$(_stage_secrets_copy_into_ansible "$license_src" "$ansible_dir" "license.txt")"
    export LICENSE_FILE="$license_dest"
    _stage_secrets_log "Staged license → ${LICENSE_FILE}"
  fi

  if [[ -n "${CM_INFO_FILE:-}" ]]; then
    local info_src info_dest info_name
    info_src="$(_stage_secrets_validate_path "CM_INFO_FILE" "$CM_INFO_FILE" "$repo_root")" || return 1
    info_name="$(basename "$info_src")"
    info_dest="$(_stage_secrets_copy_into_ansible "$info_src" "$ansible_dir" "$info_name")"
    export CM_INFO_FILE="$info_dest"
    _stage_secrets_log "Staged CM info → ${CM_INFO_FILE}"
  fi

  if [[ -n "${CM_REPO_USERNAME:-}" && -n "${CM_REPO_PASSWORD:-}" ]]; then
    export CM_REPO_USERNAME CM_REPO_PASSWORD
    _stage_secrets_log "CM archive credentials from env (user=${CM_REPO_USERNAME})"
  elif [[ -n "${CM_REPO_USERNAME:-}" || -n "${CM_REPO_PASSWORD:-}" ]]; then
    _stage_secrets_log "WARN: CM_REPO_USERNAME and CM_REPO_PASSWORD must both be set when using env creds"
  fi

  case "$phase" in
    3|cm|phase3|4|cluster|phase4|5|ecs|phase5|all|full)
      if [[ -z "${LICENSE_FILE:-}" ]] && ! find "$ansible_dir" -maxdepth 1 -type f -iname '*license*' ! -iname '*info.txt' 2>/dev/null | grep -q .; then
        _stage_secrets_log "ERROR: phase ${phase} requires a license file — set LICENSE_FILE or place *license* in ansible-playbooks/"
        return 1
      fi
      if [[ -z "${CM_INFO_FILE:-}" && ( -z "${CM_REPO_USERNAME:-}" || -z "${CM_REPO_PASSWORD:-}" ) ]]; then
        if ! find "$ansible_dir" -maxdepth 1 -type f -name '*info.txt' 2>/dev/null | grep -q .; then
          _stage_secrets_log "WARN: phase ${phase} needs CM archive creds — set CM_INFO_FILE, CM_REPO_USERNAME+PASSWORD, or *info.txt in ansible-playbooks/"
        fi
      fi
      ;;
  esac

  return 0
}
