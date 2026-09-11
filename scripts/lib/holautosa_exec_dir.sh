#!/usr/bin/env bash
# Persistent holautosa work dir (PSEAutomation HOL_AUTO_EXEC_DIR pattern).
# Terraform/Ansible state survives Jenkins CleanBeforeCheckout.

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

  printf '[holautosa-dir] Persistent state: %s (writable=%s)\n' "$env_dir" "$([[ -w "$env_dir" ]] && echo yes || echo sudo)"
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

restore_terraform_state_to_workspace() {
  local tf_dir="${1:-.}" src="${HOL_TERRAFORM_STATE_DIR:-}"
  local item pem

  [[ -n "$src" && -d "$src" ]] || return 0
  _holautosa_mkdir_p "$tf_dir"

  # Drop any stale init cache; terraform init recreates .terraform/ each build.
  rm -rf "$tf_dir/.terraform"

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

  printf '[holautosa-dir] Restored Terraform state from %s\n' "$src"
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
  rm -rf "$dest/.terraform"
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$dest/"
  done < <(find "$tf_dir" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  printf '[holautosa-dir] Persisted Terraform state to %s\n' "$dest"
}

restore_ansible_artifacts_to_workspace() {
  local repo_root="${REPO_ROOT:-.}" src="${HOL_ANSIBLE_STATE_DIR:-}"
  local ansible_dir="${repo_root}/ansible-playbooks"

  [[ -n "$src" && -d "$src" ]] || return 0
  mkdir -p "$ansible_dir"

  [[ -f "$src/inventory.ini" ]] && cp -f "$src/inventory.ini" "$ansible_dir/inventory.ini"
  [[ -f "$src/sshkey.pem" ]] && cp -f "$src/sshkey.pem" "$ansible_dir/sshkey.pem"
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$ansible_dir/"
  done < <(find "$src" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  printf '[holautosa-dir] Restored Ansible artifacts from %s\n' "$src"
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

  printf '[holautosa-dir] Persisted Ansible artifacts to %s\n' "$dest"
}
