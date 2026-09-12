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
  echo "Error: scripts/lib not found (start from repo root or ansible-playbooks)." >&2
  return 1
}

# Find ansible-playbooks regardless of flat vs nested repo layout.
resolve_ansible_playbooks_dir() {
  local start="${1:-$(pwd)}"
  local candidate=""

  for candidate in \
    "$start" \
    "$start/ansible-playbooks" \
    "$start/cdp-onprem-automation/ansible-playbooks" \
    "$(cd "$start/.." 2>/dev/null && pwd)/ansible-playbooks" \
    "$(cd "$start/../.." 2>/dev/null && pwd)/ansible-playbooks"; do
    if [[ -f "$candidate/ansible.cfg" && -f "$candidate/inventory.ini" ]]; then
      printf '%s' "$(cd "$candidate" && pwd)"
      return 0
    fi
  done

  echo "Error: ansible-playbooks directory not found (need ansible.cfg + inventory.ini)." >&2
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

# Collect matching files into a bash array (sorted, portable on macOS/Linux).
_collect_files_into() {
  local array_name="$1"
  local search_dir="$2"
  shift 2
  local -a found=()
  local item=""

  while IFS= read -r item; do
    [[ -n "$item" ]] && found+=("$item")
  done < <(find "$search_dir" -maxdepth 1 -type f "$@" 2>/dev/null | LC_ALL=C sort)

  # shellcheck disable=SC2178
  eval "$array_name=()"
  if [[ ${#found[@]} -gt 0 ]]; then
    # shellcheck disable=SC2179,SC2268
    eval "$array_name=(\"\${found[@]}\")"
  fi
}

# Prompt user to pick one file when multiple matches exist.
# Usage: prompt_select_file "message" var1 var2 ...
# Prints selected path to stdout.
prompt_select_file() {
  local prompt_msg="$1"
  shift
  local -a options=("$@")
  local choice=""
  local i=0

  if [[ ${#options[@]} -eq 0 ]]; then
    return 1
  fi

  if [[ ${#options[@]} -eq 1 ]]; then
    printf '%s' "${options[0]}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "Error: $prompt_msg" >&2
    echo "Multiple files found but stdin is not interactive. Set an explicit path env var:" >&2
    echo "  ANSIBLE_PRIVATE_KEY, LICENSE_FILE, or CM_INFO_FILE" >&2
    local f
    for f in "${options[@]}"; do
      echo "  - $f" >&2
    done
    return 1
  fi

  echo "" >&2
  echo "$prompt_msg" >&2
  i=1
  for f in "${options[@]}"; do
    echo "  $i) $(basename "$f")  ($f)" >&2
    i=$((i + 1))
  done
  echo "" >&2

  while true; do
    read -r -p "Enter choice [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s' "${options[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid selection. Enter a number between 1 and ${#options[@]}." >&2
  done
}

ansible_ssh_key_help() {
  cat <<'EOF'
SSH private key required for Ansible execution (SSH to cluster hosts).

Accepted key locations / formats:
  • ansible-playbooks/*.pem   (e.g. Terraform-generated key)
  • ansible-playbooks/id_rsa
  • ~/.ssh/id_rsa             (your default home SSH key)
  • ANSIBLE_PRIVATE_KEY=/path/to/key

Examples:
  cp my-key.pem ansible-playbooks/sshkey.pem
  ANSIBLE_PRIVATE_KEY=~/.ssh/id_rsa ./clone_and_run_pvc_automation.sh
EOF
}

ui_note_ssh_key_requirement() {
  if declare -F ui_info >/dev/null 2>&1; then
    ui_info "SSH key required for Ansible: .pem or id_rsa in ansible-playbooks/, ~/.ssh/id_rsa, or ANSIBLE_PRIVATE_KEY=/path/to/key"
  fi
}

resolve_private_key() {
  # Ansible requires an SSH private key to reach inventory hosts.
  # Search order:
  #   1. ANSIBLE_PRIVATE_KEY (explicit path)
  #   2. ansible-playbooks/*.pem, id_rsa, or idrsa
  #   3. ~/.ssh/id_rsa (default home key)
  local ansible_dir="${1:-.}"
  local -a keys=()
  local key=""

  if [[ -n "${ANSIBLE_PRIVATE_KEY:-}" && -f "${ANSIBLE_PRIVATE_KEY}" ]]; then
    printf '%s' "${ANSIBLE_PRIVATE_KEY}"
    return 0
  fi

  _collect_files_into keys "$ansible_dir" \
    \( -name "*.pem" -o -name "id_rsa" -o -name "idrsa" \)

  if [[ ${#keys[@]} -gt 0 ]]; then
    key="$(prompt_select_file "Multiple SSH private keys found in $ansible_dir — select one:" "${keys[@]}")" || return 1
    chmod 600 "$key" 2>/dev/null || true
    printf '%s' "$key"
    return 0
  fi

  if [[ -f "$HOME/.ssh/id_rsa" ]]; then
    chmod 600 "$HOME/.ssh/id_rsa" 2>/dev/null || true
    printf '%s' "$HOME/.ssh/id_rsa"
    return 0
  fi

  echo "Error: No SSH private key found in $ansible_dir or ~/.ssh/id_rsa." >&2
  ansible_ssh_key_help >&2
  return 1
}

resolve_license_file() {
  local ansible_dir="${1:-.}"
  local -a licenses=()
  local license=""

  if [[ -n "${LICENSE_FILE:-}" && -f "${LICENSE_FILE}" ]]; then
    printf '%s' "${LICENSE_FILE}"
    return 0
  fi

  _collect_files_into licenses "$ansible_dir" \
    \( -iname "*license*" ! -iname "*info.txt" \)

  if [[ ${#licenses[@]} -eq 0 ]]; then
    _collect_files_into licenses "." \
      \( -iname "*license*" ! -iname "*info.txt" \)
  fi

  if [[ ${#licenses[@]} -gt 0 ]]; then
    license="$(prompt_select_file "Multiple license files found — select one:" "${licenses[@]}")" || return 1
    printf '%s' "$license"
    return 0
  fi

  echo "Error: No license file found (expected *license* in $ansible_dir or cwd)." >&2
  echo "Set LICENSE_FILE=/path/to/license.txt and re-run." >&2
  return 1
}

ansible_cm_credentials_help() {
  cat <<'EOF'
Cloudera archive credentials (phase 3 CM install) — provide ONE of:

  1. *info.txt in ansible-playbooks/  (or CM_INFO_FILE=/path/to/info.txt)
     Format:
       login: your-cloudera-account
       password: your-password

  2. CM_REPO_USERNAME + CM_REPO_PASSWORD environment variables

  3. cm_repo_username / cm_repo_password in group_vars/all.yml

If an info file or env vars are set, the wrapper passes them as -e extra vars
and you do not need real credentials in all.yml or manual -e flags.

Other settings (cm_repo_source, cm_version, etc.) still come from all.yml.
EOF
}

ui_note_cm_credentials_requirement() {
  if declare -F ui_info >/dev/null 2>&1; then
    ui_info "CM archive creds (phase 3): use *info.txt, CM_REPO_USERNAME/PASSWORD, or all.yml — one source only"
  fi
}

load_cm_repo_credentials() {
  # Cloudera archive.cloudera.com credentials for phase 3 (CM install).
  # Only ONE source is required (first match wins):
  #   1. CM_REPO_USERNAME + CM_REPO_PASSWORD
  #   2. CM_INFO_FILE or *info.txt in ansible-playbooks/ (login:/password: lines)
  #   3. Else fall back to cm_repo_username / cm_repo_password in group_vars/all.yml
  local ansible_dir="${1:-.}"
  local -a info_files=()
  local info_file=""

  if [[ -n "${CM_REPO_USERNAME:-}" && -n "${CM_REPO_PASSWORD:-}" ]]; then
    export CM_REPO_USERID="${CM_REPO_USERNAME}"
    export CM_REPO_PASSWD="${CM_REPO_PASSWORD}"
    return 0
  fi

  if [[ -n "${CM_INFO_FILE:-}" && -f "${CM_INFO_FILE}" ]]; then
    info_file="${CM_INFO_FILE}"
  else
    _collect_files_into info_files "$ansible_dir" -name '*info.txt'
    if [[ ${#info_files[@]} -gt 0 ]]; then
      info_file="$(prompt_select_file "Multiple CM credential *info.txt files found — select one:" "${info_files[@]}")" || return 1
    fi
  fi

  if [[ -z "$info_file" ]]; then
    echo "Warning: No CM archive credentials from env or *info.txt; using group_vars/all.yml if set." >&2
    echo "  (See: ansible_cm_credentials_help or DEPLOY_PHASE=3 --help)" >&2
    return 1
  fi

  CM_REPO_USERID="$(awk -F': *' '/^login:/ {print $2}' "$info_file")"
  CM_REPO_PASSWD="$(awk -F': *' '/^password:/ {print $2}' "$info_file")"
  export CM_REPO_USERID CM_REPO_PASSWD
}

is_dry_run() {
  case "${DRY_RUN:-${ANSIBLE_DRY_RUN:-false}}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
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
  if is_dry_run; then
    args+=(--check)
    if [[ "${ANSIBLE_DIFF:-true}" != "false" ]]; then
      args+=(--diff)
    fi
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

# Copy selected license to ansible-playbooks/license.txt when needed by CM playbooks.
ensure_license_txt() {
  local ansible_dir="$1"
  local license_file="$2"
  local dest="$ansible_dir/license.txt"

  if [[ "$(realpath "$license_file" 2>/dev/null || echo "$license_file")" == "$(realpath "$dest" 2>/dev/null || echo "$dest")" ]]; then
    return 0
  fi

  cp -f "$license_file" "$dest"
  echo "Copied license to $dest"
}
