#!/usr/bin/env bash
# Jenkins: run Ansible PVC deployment wrapper for selected DEPLOY_PHASE.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"

cd "$REPO_ROOT"
export PATH="${HOME}/.local/bin:${PATH}"
# Plain ASCII in Jenkins logs (box-drawing / emoji mojibake) and no forced ANSI (piped to tee).
export UI_ASCII=1
export UI_COLOR=0
export FORCE_COLOR=0
export ANSIBLE_FORCE_COLOR="${ANSIBLE_FORCE_COLOR:-auto}"
export PY_COLORS=0
export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"
# shellcheck source=scripts/lib/holautosa_exec_dir.sh
source "$REPO_ROOT/scripts/lib/holautosa_exec_dir.sh"
prepare_holautosa_workdir || true
holautosa_log_state_manifest || true
TF_DIR="${REPO_ROOT}/terraform-code/cloudera-pvc-terraform"
restore_terraform_state_to_workspace "$TF_DIR"
# shellcheck source=scripts/lib/terraform_backend.sh
source "$REPO_ROOT/scripts/lib/terraform_backend.sh"
terraform_init_backend "$TF_DIR" 2>/dev/null || true
if command -v terraform >/dev/null 2>&1 && [[ -f "${TF_DIR}/terraform.tfstate" || -d "${TF_DIR}/terraform.tfstate.d" ]]; then
  (
    cd "$TF_DIR"
    if terraform workspace list 2>/dev/null | grep -qw "${ENVIRONMENT:-development}"; then
      terraform workspace select "${ENVIRONMENT:-development}" >/dev/null 2>&1 || true
    fi
  )
fi
restore_ansible_artifacts_to_workspace
bash "$REPO_ROOT/jenkins/scripts/regenerate-inventory-from-terraform.sh"
# Jenkins runs outside the VPC — never probe CM/portal via inventory private_ip from localhost.
export CM_API_PREFER_PRIVATE_IP="${CM_API_PREFER_PRIVATE_IP:-false}"
export ANSIBLE_CONTROLLER_OUTSIDE_VPC="${ANSIBLE_CONTROLLER_OUTSIDE_VPC:-true}"
export DEPLOYMENT_PORTAL_URL_VERIFY_SKIP_VPC="${DEPLOYMENT_PORTAL_URL_VERIFY_SKIP_VPC:-true}"
# shellcheck source=jenkins/scripts/aws-credential-check.sh
source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
aws_apply_instance_role_if_enabled
# shellcheck source=jenkins/scripts/resolve-ansible-ssh-key.sh
source "$REPO_ROOT/jenkins/scripts/resolve-ansible-ssh-key.sh"
resolve_ansible_ssh_key
bash "$REPO_ROOT/jenkins/scripts/materialize-cm-license.sh"
bash "$REPO_ROOT/jenkins/scripts/apply-ansible-group-vars.sh"
bash "$REPO_ROOT/jenkins/scripts/ansible-connectivity-preflight.sh"

export TFVARS_FILE="${TFVARS_FILE:-.tfvars.yaml}"
export DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
export DRY_RUN="${DRY_RUN:-false}"
export CONTROL_MODE="${CONTROL_MODE:-auto}"
export MONITORING_STACK_ENABLED="${MONITORING_STACK_ENABLED:-}"

LOG_FILE="$LOG_DIR/ansible-${BUILD_NUMBER:-local}-phase${DEPLOY_PHASE}.log"
log() { printf '[ansible] %s\n' "$*" | tee -a "$LOG_FILE"; }

[[ -f ansible-playbooks/inventory.ini ]] || { log "ERROR: ansible-playbooks/inventory.ini missing"; exit 1; }

# shellcheck source=scripts/lib/jenkins_log_pipe.sh
source "$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh"

log "Starting clone_and_run_pvc_automation.sh (DEPLOY_PHASE=${DEPLOY_PHASE}, DRY_RUN=${DRY_RUN})"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/jenkins/scripts/ensure-ansible.sh"
fi
set -o pipefail
jenkins_log_pipe "$LOG_FILE" ./clone_and_run_pvc_automation.sh
persist_ansible_artifacts_from_workspace || true
log "Ansible stage completed"
