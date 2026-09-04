#!/usr/bin/env bash
# Shared Ansible control-node helpers for Mac, Linux, remote laptop, or cluster node.
# Source from wrapper scripts after portable.sh.

# Resolve scripts/lib directory (repo root or nested cdp-onprem-automation).
resolve_scripts_lib() {
  local base="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  if [[ -f "$base/load_tfvars.sh" ]]; then
    printf '%s' "$base"
    return 0
  fi
  if [[ -f "$base/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s/scripts/lib' "$base"
    return 0
  fi
  if [[ -f "$base/../scripts/lib/load_tfvars.sh" ]]; then
    printf '%s/../scripts/lib' "$base"
    return 0
  fi
  echo "Error: scripts/lib not found (start from repo root or ansible-test)." >&2
  return 1
}

# Find ansible-test regardless of flat vs nested repo layout.
resolve_ansible_test_dir() {
  local start="${1:-$(pwd)}"
  local candidate=""

  for candidate in \
    "$start" \
    "$start/ansible-test" \
    "$start/cdp-onprem-automation/ansible-test" \
    "$(cd "$start/.." 2>/dev/null && pwd)/ansible-test" \
    "$(cd "$start/../.." 2>/dev/null && pwd)/ansible-test"; do
    if [[ -f "$candidate/ansible.cfg" && -f "$candidate/inventory.ini" ]]; then
      printf '%s' "$(cd "$candidate" && pwd)"
      return 0
    fi
  done

  echo "Error: ansible-test directory not found (need ansible.cfg + inventory.ini)." >&2
  return 1
}

# CONTROL_MODE: remote (default) | local | auto
detect_control_mode() {
  if [[ -n "${CONTROL_MODE:-}" ]]; then
    printf '%s' "$CONTROL_MODE"
    return 0
  fi

  local inventory="${1:-inventory.ini}"
  local short_host
  short_host="$(hostname -s 2>/dev/null || hostname)"
  local fqdn
  fqdn="$(hostname -f 2>/dev/null || hostname)"

  if [[ -f "$inventory" ]] && grep -qE "^[[:space:]]*(${short_host}|${fqdn})[[:space:]]" "$inventory"; then
    printf '%s' "local"
  else
    printf '%s' "remote"
  fi
}

resolve_private_key() {
  local ansible_dir="${1:-.}"
  local key=""

  if [[ -n "${ANSIBLE_PRIVATE_KEY:-}" && -f "${ANSIBLE_PRIVATE_KEY}" ]]; then
    printf '%s' "${ANSIBLE_PRIVATE_KEY}"
    return 0
  fi

  while IFS= read -r -d '' candidate; do
    key="$candidate"
    break
  done < <(find "$ansible_dir" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_rsa" -o -name "idrsa" \) -print0 2>/dev/null)

  if [[ -z "$key" && -f "$HOME/.ssh/id_rsa" ]]; then
    key="$HOME/.ssh/id_rsa"
  fi

  if [[ -z "$key" ]]; then
    echo "Error: No SSH private key found in $ansible_dir or ~/.ssh/id_rsa." >&2
    echo "Set ANSIBLE_PRIVATE_KEY=/path/to/key and re-run." >&2
    return 1
  fi

  chmod 600 "$key" 2>/dev/null || true
  printf '%s' "$key"
}

resolve_license_file() {
  local ansible_dir="${1:-.}"
  local license=""

  while IFS= read -r -d '' candidate; do
    license="$candidate"
    break
  done < <(find "$ansible_dir" -maxdepth 1 -type f \( -iname "*license*" ! -iname "*info.txt" \) -print0 2>/dev/null)

  if [[ -z "$license" ]]; then
    while IFS= read -r -d '' candidate; do
      license="$candidate"
      break
    done < <(find . -maxdepth 1 -type f \( -iname "*license*" ! -iname "*info.txt" \) -print0 2>/dev/null)
  fi

  if [[ -z "$license" ]]; then
    echo "Error: No license file found (expected *license* in ansible-test or cwd)." >&2
    return 1
  fi

  printf '%s' "$license"
}

load_cm_repo_credentials() {
  local ansible_dir="${1:-.}"
  local info_file=""

  if [[ -n "${CM_REPO_USERNAME:-}" && -n "${CM_REPO_PASSWORD:-}" ]]; then
    export CM_REPO_USERID="${CM_REPO_USERNAME}"
    export CM_REPO_PASSWD="${CM_REPO_PASSWORD}"
    return 0
  fi

  while IFS= read -r -d '' candidate; do
    info_file="$candidate"
    break
  done < <(find "$ansible_dir" -maxdepth 1 -type f -name '*info.txt' -print0 2>/dev/null)

  if [[ -z "$info_file" ]]; then
    echo "Warning: No *info.txt with CM archive credentials; set CM_REPO_USERNAME/CM_REPO_PASSWORD." >&2
    return 1
  fi

  CM_REPO_USERID="$(awk -F': *' '/^login:/ {print $2}' "$info_file")"
  CM_REPO_PASSWD="$(awk -F': *' '/^password:/ {print $2}' "$info_file")"
  export CM_REPO_USERID CM_REPO_PASSWD
}

ansible_extra_args() {
  local key="${1:-}"
  local args=()
  if [[ -n "$key" ]]; then
    args+=(--private-key="$key")
  fi
  if [[ -n "${ANSIBLE_LIMIT:-}" ]]; then
    args+=(--limit "$ANSIBLE_LIMIT")
  fi
  printf '%s\n' "${args[@]}"
}

patch_ansible_private_key_in_group_vars() {
  local ansible_dir="$1"
  local key="$2"
  local gv="$ansible_dir/group_vars/all.yml"
  if [[ ! -f "$gv" ]]; then
    return 0
  fi
  # portable.sh must be sourced by caller for sed_inplace
  sed_inplace "$gv" "/^ansible_ssh_private_key_file:/c\\
ansible_ssh_private_key_file: $key
"
}
