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

prepare_holautosa_workdir() {
  local user base env_dir
  user="$(holautosa_exec_user)"
  base="$(holautosa_exec_base)"
  env_dir="$(holautosa_env_dir)"

  if [[ ! -d "/home/${user}" ]]; then
    printf '[holautosa-dir] ERROR: home not found: /home/%s\n' "$user" >&2
    return 1
  fi

  if [[ "$(id -un)" == "$user" ]]; then
    mkdir -p "${env_dir}/terraform" "${env_dir}/ansible"
  elif sudo -n -u "$user" -- true 2>/dev/null; then
    sudo -n -u "$user" -- mkdir -p "${env_dir}/terraform" "${env_dir}/ansible"
    sudo -n -u "$user" -- chmod -R u+rwX,g+rwX "${base}/cdp-onprem-automation" 2>/dev/null || true
  else
    mkdir -p "${env_dir}/terraform" "${env_dir}/ansible" 2>/dev/null || {
      printf '[holautosa-dir] ERROR: cannot create %s (need sudo to %s)\n' "$env_dir" "$user" >&2
      return 1
    }
  fi

  export HOL_ENV_DIR="$env_dir"
  export HOL_TERRAFORM_STATE_DIR="${env_dir}/terraform"
  export HOL_ANSIBLE_STATE_DIR="${env_dir}/ansible"
  export TF_STATE_BACKEND=local

  printf '[holautosa-dir] Persistent state: %s\n' "$env_dir"
}

restore_terraform_state_to_workspace() {
  local tf_dir="${1:-.}" src="${HOL_TERRAFORM_STATE_DIR:-}"
  local item pem

  [[ -n "$src" && -d "$src" ]] || return 0

  for item in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$src/$item" ]] && cp -f "$src/$item" "$tf_dir/$item"
  done
  if [[ -d "$src/terraform.tfstate.d" ]]; then
    mkdir -p "$tf_dir/terraform.tfstate.d"
    cp -a "$src/terraform.tfstate.d/." "$tf_dir/terraform.tfstate.d/"
  fi
  if [[ -d "$src/.terraform" ]]; then
    mkdir -p "$tf_dir/.terraform"
    cp -a "$src/.terraform/." "$tf_dir/.terraform/"
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
  mkdir -p "$dest"

  for item in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$tf_dir/$item" ]] && cp -f "$tf_dir/$item" "$dest/$item"
  done
  if [[ -d "$tf_dir/terraform.tfstate.d" ]]; then
    mkdir -p "$dest/terraform.tfstate.d"
    cp -a "$tf_dir/terraform.tfstate.d/." "$dest/terraform.tfstate.d/"
  fi
  if [[ -d "$tf_dir/.terraform" ]]; then
    mkdir -p "$dest/.terraform"
    cp -a "$tf_dir/.terraform/." "$dest/.terraform/"
  fi
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
  mkdir -p "$dest"

  [[ -f "$ansible_dir/inventory.ini" ]] && cp -f "$ansible_dir/inventory.ini" "$dest/inventory.ini"
  [[ -f "$ansible_dir/sshkey.pem" ]] && cp -f "$ansible_dir/sshkey.pem" "$dest/sshkey.pem"
  while IFS= read -r pem; do
    [[ -n "$pem" ]] && cp -f "$pem" "$dest/"
  done < <(find "$ansible_dir" -maxdepth 1 -type f -name '*.pem' 2>/dev/null || true)

  printf '[holautosa-dir] Persisted Ansible artifacts to %s\n' "$dest"
}
