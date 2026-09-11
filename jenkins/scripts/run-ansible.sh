#!/usr/bin/env bash
# Jenkins: run Ansible PVC deployment wrapper for selected DEPLOY_PHASE.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"

cd "$REPO_ROOT"
export PATH="${HOME}/.local/bin:${PATH}"
export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"
# shellcheck source=scripts/lib/holautosa_exec_dir.sh
source "$REPO_ROOT/scripts/lib/holautosa_exec_dir.sh"
prepare_holautosa_workdir || true
restore_ansible_artifacts_to_workspace
bash "$REPO_ROOT/jenkins/scripts/regenerate-inventory-from-terraform.sh"
# shellcheck source=jenkins/scripts/aws-credential-check.sh
source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
aws_apply_instance_role_if_enabled
# shellcheck source=jenkins/scripts/resolve-ansible-ssh-key.sh
source "$REPO_ROOT/jenkins/scripts/resolve-ansible-ssh-key.sh"
resolve_ansible_ssh_key
bash "$REPO_ROOT/jenkins/scripts/ansible-connectivity-preflight.sh"

export TFVARS_FILE="${TFVARS_FILE:-.tfvars.yaml}"
export DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
export DRY_RUN="${DRY_RUN:-false}"
export CONTROL_MODE="${CONTROL_MODE:-auto}"

LOG_FILE="$LOG_DIR/ansible-${BUILD_NUMBER:-local}-phase${DEPLOY_PHASE}.log"
log() { printf '[ansible] %s\n' "$*" | tee -a "$LOG_FILE"; }

[[ -f ansible-playbooks/inventory.ini ]] || { log "ERROR: ansible-playbooks/inventory.ini missing"; exit 1; }

log "Starting clone_and_run_pvc_automation.sh (DEPLOY_PHASE=${DEPLOY_PHASE}, DRY_RUN=${DRY_RUN})"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/jenkins/scripts/ensure-ansible.sh"
fi
set -o pipefail
./clone_and_run_pvc_automation.sh 2>&1 | tee -a "$LOG_FILE"
persist_ansible_artifacts_from_workspace || true
log "Ansible stage completed"
