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

resolve_effective_ansible_cm_version() {
  local ansible_dir="${1:?ansible playbooks directory is required}"
  python3 - "$ansible_dir" "${ANSIBLE_GROUP_VARS_OVERRIDE_FILE:-}" <<'PY'
import sys
from pathlib import Path

import yaml

ansible_dir = Path(sys.argv[1])
override_path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
value = ""
paths = [
    ansible_dir / "group_vars" / "all.yml",
    ansible_dir / "config.yml",
]
if override_path:
    paths.append(override_path)

for path in paths:
    if not path.is_file():
        continue
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if isinstance(data, dict) and data.get("cm_version") not in (None, ""):
        value = str(data["cm_version"])

print(value)
PY
}
