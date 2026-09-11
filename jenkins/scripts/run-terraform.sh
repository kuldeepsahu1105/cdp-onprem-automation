#!/usr/bin/env bash
# Jenkins: run Terraform wrapper (plan or apply based on DRY_RUN).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"

cd "$REPO_ROOT"
export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"
# shellcheck source=jenkins/scripts/aws-credential-check.sh
source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
aws_apply_instance_role_if_enabled

export TFVARS_FILE="${TFVARS_FILE:-.tfvars.yaml}"
export DRY_RUN="${DRY_RUN:-false}"
export SHOW_TF_PLAN_OUTPUT="${SHOW_TF_PLAN_OUTPUT:-false}"
export LOG_DIR="${LOG_DIR}"

LOG_FILE="$LOG_DIR/terraform-${BUILD_NUMBER:-local}.log"
log() { printf '[terraform] %s\n' "$*" | tee -a "$LOG_FILE"; }

# shellcheck source=scripts/lib/holautosa_exec_dir.sh
source "$REPO_ROOT/scripts/lib/holautosa_exec_dir.sh"
prepare_holautosa_workdir || true
holautosa_purge_terraform_module_cache "$REPO_ROOT/terraform-code/cloudera-pvc-terraform"

log "Git commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "Starting clone_and_run_terraform.sh (DRY_RUN=${DRY_RUN}, SHOW_TF_PLAN_OUTPUT=${SHOW_TF_PLAN_OUTPUT}, AWS creds=${AWS_SHARED_CREDENTIALS_FILE:-instance-role-env}, user=$(id -un))"
set -o pipefail
./clone_and_run_terraform.sh 2>&1 | tee -a "$LOG_FILE"
log "Terraform stage completed"
