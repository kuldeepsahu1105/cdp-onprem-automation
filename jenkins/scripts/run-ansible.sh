#!/usr/bin/env bash
# Jenkins: run Ansible PVC deployment wrapper for selected DEPLOY_PHASE.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"

cd "$REPO_ROOT"
export TFVARS_FILE="${TFVARS_FILE:-.tfvars.yaml}"
export DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
export DRY_RUN="${DRY_RUN:-false}"
export CONTROL_MODE="${CONTROL_MODE:-auto}"

LOG_FILE="$LOG_DIR/ansible-${BUILD_NUMBER:-local}-phase${DEPLOY_PHASE}.log"
log() { printf '[ansible] %s\n' "$*" | tee -a "$LOG_FILE"; }

[[ -f ansible-playbooks/inventory.ini ]] || { log "ERROR: ansible-playbooks/inventory.ini missing"; exit 1; }

log "Starting clone_and_run_pvc_automation.sh (DEPLOY_PHASE=${DEPLOY_PHASE}, DRY_RUN=${DRY_RUN})"
set -o pipefail
./clone_and_run_pvc_automation.sh 2>&1 | tee -a "$LOG_FILE"
log "Ansible stage completed"
