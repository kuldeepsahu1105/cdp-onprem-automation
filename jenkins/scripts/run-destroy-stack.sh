#!/usr/bin/env bash
# Jenkins: optional Ansible 99_cleanup, then terraform destroy (same tfvars/workspace as deploy).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"

cd "$REPO_ROOT"
export PATH="${HOME}/.local/bin:${PATH}"
export UI_ASCII=1
export UI_COLOR=0
export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"

is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

LOG_FILE="$LOG_DIR/destroy-stack-${BUILD_NUMBER:-local}.log"
log() { printf '[destroy-stack] %s\n' "$*" | tee -a "$LOG_FILE"; }

if is_enabled "${CLEANUP_BEFORE_DESTROY:-false}"; then
  log "CLEANUP_BEFORE_DESTROY=true — running 99_cleanup.yml (e2e) before terraform destroy"
  # shellcheck source=scripts/lib/holautosa_exec_dir.sh
  source "$REPO_ROOT/scripts/lib/holautosa_exec_dir.sh"
  prepare_holautosa_workdir || true
  TF_DIR="${REPO_ROOT}/terraform-code/cloudera-pvc-terraform"
  restore_terraform_state_to_workspace "$TF_DIR"
  # shellcheck source=scripts/lib/terraform_backend.sh
  source "$REPO_ROOT/scripts/lib/terraform_backend.sh"
  terraform_init_backend "$TF_DIR" 2>/dev/null || true
  restore_ansible_artifacts_to_workspace
  bash "$REPO_ROOT/jenkins/scripts/regenerate-inventory-from-terraform.sh"
  # shellcheck source=jenkins/scripts/aws-credential-check.sh
  source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
  aws_apply_instance_role_if_enabled
  # shellcheck source=jenkins/scripts/resolve-ansible-ssh-key.sh
  source "$REPO_ROOT/jenkins/scripts/resolve-ansible-ssh-key.sh"
  resolve_ansible_ssh_key
  bash "$REPO_ROOT/jenkins/scripts/apply-ansible-group-vars.sh"
  [[ -f ansible-playbooks/inventory.ini ]] || { log "ERROR: inventory.ini required for cleanup"; exit 1; }
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/jenkins/scripts/ensure-ansible.sh"
  fi
  (
    cd ansible-playbooks
    ansible-playbook -i inventory.ini 99_cleanup.yml \
      -e cleanup_enabled=true \
      -e cleanup_confirm=true \
      -e cleanup_e2e=true
  ) 2>&1 | tee -a "$LOG_FILE"
  log "Ansible cleanup completed"
else
  log "Skipping Ansible cleanup (CLEANUP_BEFORE_DESTROY not set)"
fi

export DESTROY_STACK_CONFIRM="${DESTROY_STACK_CONFIRM:-false}"
export DRY_RUN="${DRY_RUN:-false}"
bash "$REPO_ROOT/jenkins/scripts/run-terraform-destroy.sh"
