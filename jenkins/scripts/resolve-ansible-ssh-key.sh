#!/usr/bin/env bash
# Prefer Terraform-generated PEM for Ansible; fall back to CREDENTIALS_USER ~/.ssh.

resolve_ansible_ssh_key() {
  local repo_root="${REPO_ROOT:-${WORKSPACE:-.}}"
  local ansible_dir="${repo_root}/ansible-playbooks"
  local tf_dir="${repo_root}/terraform-code/cloudera-pvc-terraform"
  local pem=""

  if [[ -f "${ansible_dir}/sshkey.pem" ]]; then
    export ANSIBLE_PRIVATE_KEY="${ansible_dir}/sshkey.pem"
    printf '[ansible-ssh] ANSIBLE_PRIVATE_KEY=%s (terraform sshkey.pem)\n' "$ANSIBLE_PRIVATE_KEY"
    return 0
  fi

  pem="$(find "$ansible_dir" "$tf_dir" -maxdepth 1 -type f -name '*.pem' 2>/dev/null | head -1 || true)"
  if [[ -n "$pem" && -f "$pem" ]]; then
    export ANSIBLE_PRIVATE_KEY="$pem"
    printf '[ansible-ssh] ANSIBLE_PRIVATE_KEY=%s (terraform-generated)\n' "$ANSIBLE_PRIVATE_KEY"
    return 0
  fi

  # shellcheck source=jenkins/scripts/apply-credentials-user.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-credentials-user.sh"
  apply_credentials_user_ssh
}
