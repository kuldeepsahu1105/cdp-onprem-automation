#!/usr/bin/env bash
# Persistent holautosa work dir (PSEAutomation HOL_AUTO_EXEC_DIR pattern).
# Terraform/Ansible state survives Jenkins CleanBeforeCheckout.

_holautosa_output_init() {
  if [[ -z "${_HOLAUTOSA_OUTPUT_INIT:-}" && -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output_mode.sh" ]]; then
    # shellcheck source=scripts/lib/output_mode.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output_mode.sh"
    _HOLAUTOSA_OUTPUT_INIT=1
  fi
}

holautosa_exec_user() {
  printf '%s' "${CREDENTIALS_USER:-holautosa}"
}

holautosa_exec_base() {
  local user base
  user="$(holautosa_exec_user)"
  base="${HOL_AUTO_EXEC_DIR:-/home/${user}/HOL_AUTO_EXEC_DIR}"
  printf '%s' "$base"
}

holautosa_env_dir() {
  printf '%s/cdp-onprem-automation/%s' "$(holautosa_exec_base)" "${ENVIRONMENT:-development}"
}

_holautosa_sudo_as_user() {
  local user="$1"
  shift
  sudo -n -u "$user" -- "$@"
}

_holautosa_grant_jenkins_write() {
  local tree="$1"
  local run_user
  run_user="$(id -un)"
  # PSEAutomation: chown holautosa work files to jenkins for pipeline read/write.
  if sudo -n chown -R "${run_user}:$(id -gn)" "$tree" 2>/dev/null; then
    return 0
  fi
  if sudo -n chown -R jenkins:jenkins "$tree" 2>/dev/null; then
    return 0
  fi
  sudo -n chmod -R u+rwX,g+rwX "$tree" 2>/dev/null || true
}

prepare_holautosa_workdir() {
  local user base env_dir tree
  user="$(holautosa_exec_user)"
  base="$(holautosa_exec_base)"
  env_dir="$(holautosa_env_dir)"
  tree="${base}/cdp-onprem-automation"

  if [[ ! -d "/home/${user}" ]]; then
    printf '[holautosa-dir] ERROR: home not found: /home/%s\n' "$user" >&2
    return 1
  fi

  if [[ "$(id -un)" == "$user" ]]; then
    mkdir -p "${env_dir}/terraform" "${env_dir}/ansible"
  elif [[ -d "$tree" && -w "$tree" ]]; then
    mkdir -p "${env_dir}/terraform" "${env_dir}/ansible"
  elif _holautosa_sudo_as_user "$user" mkdir -p "${env_dir}/terraform" "${env_dir}/ansible"; then
    _holautosa_grant_jenkins_write "$tree"
  elif sudo -n mkdir -p "${env_dir}/terraform" "${env_dir}/ansible"; then
    _holautosa_grant_jenkins_write "$tree"
  else
    printf '[holautosa-dir] ERROR: cannot create %s\n' "$env_dir" >&2
    printf '[holautosa-dir] Hint: jenkins ALL=(holautosa) NOPASSWD: ALL in sudoers\n' >&2
    printf '[holautosa-dir] Or: sudo mkdir -p %s && sudo chown -R jenkins:jenkins %s\n' "$tree" "$tree" >&2
    return 1
  fi

  export HOL_ENV_DIR="$env_dir"
  export HOL_TERRAFORM_STATE_DIR="${env_dir}/terraform"
  export HOL_ANSIBLE_STATE_DIR="${env_dir}/ansible"
  export TF_STATE_BACKEND=local

  # Legacy builds persisted .terraform/ here; remove so restore never copies it.
  _holautosa_clean_legacy_terraform_cache "$HOL_TERRAFORM_STATE_DIR"

  _holautosa_output_init
  log_detail "[holautosa-dir] Persistent state: $env_dir (writable=$([[ -w "$env_dir" ]] && echo yes || echo sudo))"
}

_holautosa_mkdir_p() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    return 0
  fi
  if mkdir -p "$dir" 2>/dev/null; then
    return 0
  fi
  local user
  user="$(holautosa_exec_user)"
  _holautosa_sudo_as_user "$user" mkdir -p "$dir" || sudo -n mkdir -p "$dir"
}

_holautosa_rm_rf() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  if rm -rf "$target" 2>/dev/null; then
    return 0
  fi
  local user
  user="$(holautosa_exec_user)"
  _holautosa_sudo_as_user "$user" rm -rf "$target" 2>/dev/null \
    || sudo -n rm -rf "$target" 2>/dev/null \
    || true
}

_holautosa_clean_legacy_terraform_cache() {
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  if [[ -d "$dir/.terraform" ]]; then
    _holautosa_rm_rf "$dir/.terraform"
    _holautosa_output_init
    log_verbose "[holautosa-dir] Removed legacy .terraform cache under $dir"
  fi
}

# Jenkins preflight: drop module/provider cache everywhere we no longer persist it.
holautosa_purge_terraform_module_cache() {
  local tf_dir="${1:-.}"
  _holautosa_clean_legacy_terraform_cache "$tf_dir"
  if [[ -n "${HOL_TERRAFORM_STATE_DIR:-}" ]]; then
    _holautosa_clean_legacy_terraform_cache "$HOL_TERRAFORM_STATE_DIR"
  fi
}

restore_terraform_state_to_workspace() {
  local tf_dir="${1:-.}" src="${HOL_TERRAFORM_STATE_DIR:-}"
  local item pem

  [[ -n "$src" && -d "$src" ]] || return 0
  _holautosa_output_init
  log_verbose "[holautosa-dir] State restore v2 (state files only; no .terraform cache)"
  _holautosa_mkdir_p "$tf_dir"

  # Drop any stale init cache; terraform init recreates .terraform/ each build.
  holautosa_purge_terraform_module_cache "$tf_dir"

  for item in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$src/$item" ]] && cp -f "$src/$item" "$tf_dir/$item"
  done
  if [[ -d "$src/terraform.tfstate.d" ]]; then
    _holautosa_mkdir_p "$tf_dir/terraform.tfstate.d"
    cp -a "$src/terraform.tfstate.d/." "$tf_dir/terraform.tfstate.d/"
  fi
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$tf_dir/"
  done < <(find "$src" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  log_verbose "[holautosa-dir] Restored Terraform state from $src"
}

persist_terraform_state_from_workspace() {
  local tf_dir="${1:-.}" dest="${HOL_TERRAFORM_STATE_DIR:-}"
  local item pem

  [[ -n "$dest" ]] || return 0
  _holautosa_mkdir_p "$dest"

  for item in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$tf_dir/$item" ]] && cp -f "$tf_dir/$item" "$dest/$item"
  done
  if [[ -d "$tf_dir/terraform.tfstate.d" ]]; then
    _holautosa_mkdir_p "$dest/terraform.tfstate.d"
    cp -a "$tf_dir/terraform.tfstate.d/." "$dest/terraform.tfstate.d/"
  fi
  # Remove legacy .terraform cache from holautosa (no longer persisted).
  _holautosa_clean_legacy_terraform_cache "$dest"
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$dest/"
  done < <(find "$tf_dir" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  holautosa_write_state_manifest "${REPO_ROOT:-.}"
  log_verbose "[holautosa-dir] Persisted Terraform state to $dest"
}

restore_ansible_artifacts_to_workspace() {
  local repo_root="${REPO_ROOT:-.}" src="${HOL_ANSIBLE_STATE_DIR:-}"
  local ansible_dir="${repo_root}/ansible-playbooks"

  [[ -n "$src" && -d "$src" ]] || return 0
  mkdir -p "$ansible_dir"

  # inventory.ini is regenerated from Terraform (public IPs). Restoring a stale
  # holautosa copy often points ansible_host at private VPC addresses Jenkins cannot reach.
  [[ -f "$src/sshkey.pem" ]] && cp -f "$src/sshkey.pem" "$ansible_dir/sshkey.pem"
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$ansible_dir/"
  done < <(find "$src" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  log_verbose "[holautosa-dir] Restored Ansible SSH keys from $src (inventory from Terraform)"
}

persist_ansible_artifacts_from_workspace() {
  local repo_root="${REPO_ROOT:-.}" dest="${HOL_ANSIBLE_STATE_DIR:-}"
  local ansible_dir="${repo_root}/ansible-playbooks"

  [[ -n "$dest" ]] || return 0
  _holautosa_mkdir_p "$dest"

  [[ -f "$ansible_dir/inventory.ini" ]] && cp -f "$ansible_dir/inventory.ini" "$dest/inventory.ini"
  [[ -f "$ansible_dir/sshkey.pem" ]] && cp -f "$ansible_dir/sshkey.pem" "$dest/sshkey.pem"
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$dest/"
  done < <(find "$ansible_dir" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  holautosa_write_state_manifest "$repo_root"
  log_verbose "[holautosa-dir] Persisted Ansible artifacts to $dest"
}

# Single manifest tying holautosa artifacts together (debugging re-run mismatches).
holautosa_write_state_manifest() {
  local repo_root="${1:-${REPO_ROOT:-.}}"
  local env_dir manifest tf_dir ansible_dir pem_sha inv_sha tf_serial git_commit
  env_dir="$(holautosa_env_dir)"
  manifest="${env_dir}/state_manifest.json"
  tf_dir="${repo_root}/terraform-code/cloudera-pvc-terraform"
  ansible_dir="${repo_root}/ansible-playbooks"

  [[ -d "$env_dir" ]] || return 0
  _holautosa_mkdir_p "$env_dir"

  pem_sha=""
  if [[ -f "${ansible_dir}/sshkey.pem" ]]; then
    pem_sha="$(sha256sum "${ansible_dir}/sshkey.pem" 2>/dev/null | awk '{print $1}' || true)"
  elif [[ -f "${HOL_ANSIBLE_STATE_DIR:-}/sshkey.pem" ]]; then
    pem_sha="$(sha256sum "${HOL_ANSIBLE_STATE_DIR}/sshkey.pem" 2>/dev/null | awk '{print $1}' || true)"
  fi

  inv_sha=""
  [[ -f "${ansible_dir}/inventory.ini" ]] && \
    inv_sha="$(sha256sum "${ansible_dir}/inventory.ini" 2>/dev/null | awk '{print $1}' || true)"

  tf_serial=""
  if [[ -f "${tf_dir}/terraform.tfstate" ]]; then
    tf_serial="$(jq -r '.serial // empty' "${tf_dir}/terraform.tfstate" 2>/dev/null || true)"
  fi

  git_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"

  cat >"$manifest" <<EOF
{
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "${ENVIRONMENT:-development}",
  "build_number": "${BUILD_NUMBER:-local}",
  "git_commit": "${git_commit}",
  "keypair_name": "${KEYPAIR_NAME:-}",
  "terraform_state_serial": ${tf_serial:-null},
  "sshkey_sha256": "${pem_sha}",
  "inventory_sha256": "${inv_sha}",
  "hol_terraform_dir": "${HOL_TERRAFORM_STATE_DIR:-}",
  "hol_ansible_dir": "${HOL_ANSIBLE_STATE_DIR:-}"
}
EOF
  log_verbose "[holautosa-dir] Wrote state manifest $manifest"
}

holautosa_log_state_manifest() {
  local manifest summary
  manifest="$(holautosa_env_dir)/state_manifest.json"
  [[ -f "$manifest" ]] || return 0
  _holautosa_output_init
  if output_is_quiet; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    summary="$(jq -r '"build=\(.build_number) env=\(.environment) pem=\(.sshkey_sha256[0:12])…"' \
      "$manifest" 2>/dev/null || true)"
    [[ -n "$summary" ]] && log_detail "[holautosa-dir] state manifest: $summary" && return 0
  fi
  log_detail "[holautosa-dir] Last persisted state manifest:"
  sed 's/^/[holautosa-dir]   /' "$manifest" | while IFS= read -r line; do log_detail "$line"; done
}
