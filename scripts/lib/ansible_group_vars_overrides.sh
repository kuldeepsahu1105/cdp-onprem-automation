#!/usr/bin/env bash
# Render ansible-playbooks/jenkins_override.yml and pass via ansible -e @file.
# Do NOT write under group_vars/all/ — that directory shadows group_vars/all.yml
# and Ansible drops ansible_user (defaults to jenkins on the Jenkins agent).

apply_ansible_group_vars_overrides() {
  local repo_root="${1:-${REPO_ROOT:-.}}"
  local ansible_dir="${2:-${repo_root}/ansible-playbooks}"
  local dest="${ansible_dir}/jenkins_override.yml"
  local renderer="${repo_root}/jenkins/scripts/render-ansible-group-vars-override.py"
  local legacy_file="${ansible_dir}/group_vars/all/jenkins_override.yml"
  local legacy_dir="${ansible_dir}/group_vars/all"

  if [[ -f "$legacy_file" ]]; then
    rm -f "$legacy_file"
    rmdir "$legacy_dir" 2>/dev/null || true
    printf '[ansible-vars] Removed legacy %s (shadowed group_vars/all.yml)\n' "$legacy_file" >&2
  fi

  if [[ ! -f "$renderer" ]]; then
    printf '[ansible-vars] WARN: renderer not found: %s\n' "$renderer" >&2
    unset ANSIBLE_GROUP_VARS_OVERRIDE_FILE
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf '[ansible-vars] ERROR: python3 required for group_vars overrides\n' >&2
    return 1
  fi

  python3 "$renderer" "$dest"
  if [[ -f "$dest" ]]; then
    export ANSIBLE_GROUP_VARS_OVERRIDE_FILE="$dest"
  else
    unset ANSIBLE_GROUP_VARS_OVERRIDE_FILE
  fi
}
