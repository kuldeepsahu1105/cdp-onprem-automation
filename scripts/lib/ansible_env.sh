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

# Write CM license from pipeline env or CLI when no *license* file exists on the controller.
# Sources (first match): LICENSE_FILE, CM_LICENSE_CONTENT_FILE, CM_LICENSE_CONTENT env.
materialize_cm_license_content() {
  local ansible_dir="${1:-.}"

  if [[ -n "${LICENSE_FILE:-}" && -f "${LICENSE_FILE}" ]]; then
    return 0
  fi

  local src_file="${CM_LICENSE_CONTENT_FILE:-}"
  if [[ -n "$src_file" && -f "$src_file" ]]; then
    export LICENSE_FILE="$src_file"
    printf '[license] Using license file from CM_LICENSE_CONTENT_FILE=%s\n' "$LICENSE_FILE"
    return 0
  fi

  local content="${CM_LICENSE_CONTENT:-}"
  if [[ -z "${content//[[:space:]]/}" ]]; then
    return 0
  fi

  local dest="${ansible_dir}/license.txt"
  printf '%s' "$content" > "$dest"
  chmod 600 "$dest" 2>/dev/null || true
  export LICENSE_FILE="$dest"
  printf '[license] Wrote license from CM_LICENSE_CONTENT to %s\n' "$dest"
}

resolve_license_file() {
  local ansible_dir="${1:-.}"
  local -a licenses=()
  local license=""

  materialize_cm_license_content "$ansible_dir"

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

# Collections named in ansible-playbooks/requirements.yml (used to skip redundant galaxy runs).
_ansible_requirements_collections_present() {
  local req="${1:?requirements.yml path}"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == git+* ]]; then
      if ! ansible-galaxy collection list cloudera.cluster 2>/dev/null | grep -qE 'cloudera\.cluster'; then
        return 1
      fi
      # requirements.yml pins cloudera.cluster v4.x — v5/devel must trigger reinstall
      local cc_versions
      cc_versions="$(ansible-galaxy collection list cloudera.cluster 2>/dev/null | awk '$1=="cloudera.cluster" {print $2}')"
      if [[ -z "$cc_versions" ]]; then
        return 1
      fi
      if grep -qE '^5\.' <<<"$cc_versions"; then
        return 1
      fi
      if ! grep -qE '^4\.' <<<"$cc_versions"; then
        return 1
      fi
      # v4.0.0–v4.3.x lack plugins/modules/cluster.py (31/33 need cloudera.cluster.cluster).
      local cc_ver cluster_mod
      cc_ver="$(ansible-galaxy collection list cloudera.cluster 2>/dev/null | awk '$1=="cloudera.cluster" {print $2; exit}')"
      if [[ -z "$cc_ver" ]] || [[ "$(printf '%s\n' '4.4.0' "$cc_ver" | sort -V | head -1)" != "4.4.0" ]]; then
        return 1
      fi
      cluster_mod="${HOME}/.ansible/collections/ansible_collections/cloudera/cluster/plugins/modules/cluster.py"
      if [[ ! -f "$cluster_mod" ]] && [[ ! -f /usr/share/ansible/collections/ansible_collections/cloudera/cluster/plugins/modules/cluster.py ]]; then
        return 1
      fi
    elif ! ansible-galaxy collection list "$name" 2>/dev/null | grep -qF "$name"; then
      return 1
    fi
  done < <(awk '/^[[:space:]]+- name:/ { sub(/^[[:space:]]+- name:[[:space:]]*/, ""); print }' "$req")
  return 0
}

# CI pipelines run one DEPLOY_PHASE per stage; each invokes pvc_setup.sh — install collections once.
ansible_install_collections_if_needed() {
  local req="${1:?requirements.yml path}"
  case "${PVC_SKIP_GALAXY_INSTALL:-}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
  esac
  if _ansible_requirements_collections_present "$req"; then
    return 0
  fi
  printf '%s\n' "Installing Ansible collections from requirements.yml"
  ansible-galaxy collection install -r "$req"
}

# Jenkins ansiColor + jenkins_log_pipe: stdout is piped (not a TTY) but the console renders ANSI.
ci_ansi_console_enabled() {
  [[ "${ANSIBLE_CI_CONSOLE:-${JENKINS_ANSI_CONSOLE:-}}" == "1" ]] && [[ "${TERM:-}" != "dumb" ]]
}

ci_ansi_prepare_jenkins_console() {
  [[ -n "${BUILD_NUMBER:-}${JENKINS_URL:-}" ]] || return 0
  case "${TERM:-}" in
    ''|dumb) export TERM=xterm ;;
  esac
  export JENKINS_ANSI_CONSOLE=1
  export ANSIBLE_CI_CONSOLE=1
}

# Ansible colors on an interactive TTY, or CI console with forced ANSI (piped log tee strips ANSI for artifacts).
ansible_ci_ansi_console() {
  ci_ansi_console_enabled
}

ansible_configure_output() {
  case "${ANSIBLE_NOCOLOR:-${NO_COLOR:-}}" in
    1|true|yes|TRUE|YES|on|ON)
      export ANSIBLE_FORCE_COLOR=0
      export PY_COLORS=0
      return 0
      ;;
  esac
  case "${ANSIBLE_FORCE_COLOR:-auto}" in
    0|false|no|off)
      export ANSIBLE_FORCE_COLOR=0
      export PY_COLORS=0
      return 0
      ;;
    1|true|yes|on|force)
      if [[ "${ANSIBLE_SCRIPT_TTY:-${JENKINS_SCRIPT_TTY:-}}" == "1" ]] || ansible_ci_ansi_console || [[ -t 1 ]]; then
        export ANSIBLE_FORCE_COLOR=1
        export PY_COLORS=1
      else
        export ANSIBLE_FORCE_COLOR=0
        export PY_COLORS=0
      fi
      return 0
      ;;
    auto|*)
      if [[ "${ANSIBLE_SCRIPT_TTY:-${JENKINS_SCRIPT_TTY:-}}" == "1" ]] || ansible_ci_ansi_console \
        || { [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; }; then
        export ANSIBLE_FORCE_COLOR=1
        export PY_COLORS=1
      else
        export ANSIBLE_FORCE_COLOR=0
        export PY_COLORS=0
      fi
      ;;
  esac
}

ansible_extra_args() {
  local key="${1:-}"
  local args=()
  if [[ -n "$key" ]]; then
    export ANSIBLE_PRIVATE_KEY="$key"
    args+=(--private-key="$key")
  fi
  if [[ -n "${ANSIBLE_LIMIT:-}" ]]; then
    args+=(--limit "$ANSIBLE_LIMIT")
  fi
  if [[ -n "${ANSIBLE_GROUP_VARS_OVERRIDE_FILE:-}" && -f "${ANSIBLE_GROUP_VARS_OVERRIDE_FILE}" ]]; then
    args+=(-e "@${ANSIBLE_GROUP_VARS_OVERRIDE_FILE}")
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
  if grep -q '^cm_private_key_path:' "$gv"; then
    sed_inplace "$gv" "/^cm_private_key_path:/c\\
cm_private_key_path: $key
"
  fi
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
