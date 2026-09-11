#!/usr/bin/env bash
# Render ansible-playbooks/group_vars/all/jenkins_override.yml from Jenkins params / env.

apply_ansible_group_vars_overrides() {
  local repo_root="${1:-${REPO_ROOT:-.}}"
  local ansible_dir="${2:-${repo_root}/ansible-playbooks}"
  local dest="${ansible_dir}/group_vars/all/jenkins_override.yml"
  local renderer="${repo_root}/jenkins/scripts/render-ansible-group-vars-override.py"

  if [[ ! -f "$renderer" ]]; then
    printf '[ansible-vars] WARN: renderer not found: %s\n' "$renderer" >&2
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf '[ansible-vars] ERROR: python3 required for group_vars overrides\n' >&2
    return 1
  fi

  python3 "$renderer" "$dest"
}
