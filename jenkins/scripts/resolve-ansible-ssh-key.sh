#!/usr/bin/env bash
# Prefer Terraform-generated PEM for Ansible; fall back to CREDENTIALS_USER ~/.ssh.

_REPO_ROOT_FOR_SSH="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [[ -f "${_REPO_ROOT_FOR_SSH}/scripts/lib/output_mode.sh" ]]; then
  # shellcheck source=scripts/lib/output_mode.sh
  source "${_REPO_ROOT_FOR_SSH}/scripts/lib/output_mode.sh"
fi

resolve_ansible_ssh_key() {
  local repo_root="${REPO_ROOT:-${WORKSPACE:-.}}"
  local ansible_dir="${repo_root}/ansible-playbooks"
  local tf_dir="${repo_root}/terraform-code/cloudera-pvc-terraform"
  local pem=""

  if [[ -f "${ansible_dir}/sshkey.pem" ]]; then
    chmod 600 "${ansible_dir}/sshkey.pem" 2>/dev/null || true
    export ANSIBLE_PRIVATE_KEY="${ansible_dir}/sshkey.pem"
    log_verbose "[ansible-ssh] ANSIBLE_PRIVATE_KEY=$ANSIBLE_PRIVATE_KEY (terraform sshkey.pem)"
    return 0
  fi

  pem="$(find "$ansible_dir" "$tf_dir" -maxdepth 1 -type f -name '*.pem' 2>/dev/null | head -1 || true)"
  if [[ -n "$pem" && -f "$pem" ]]; then
    chmod 600 "$pem" 2>/dev/null || true
    export ANSIBLE_PRIVATE_KEY="$pem"
    log_verbose "[ansible-ssh] ANSIBLE_PRIVATE_KEY=$ANSIBLE_PRIVATE_KEY (terraform-generated)"
    return 0
  fi

  # shellcheck source=jenkins/scripts/apply-credentials-user.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-credentials-user.sh"
  apply_credentials_user_ssh
}
