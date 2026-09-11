#!/usr/bin/env bash
# Regenerate ansible-playbooks/inventory.ini from Terraform outputs (public ansible_host).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform-code/cloudera-pvc-terraform}"
GEN_SCRIPT="${GEN_SCRIPT:-$REPO_ROOT/generate_inventory.sh}"
DEST_INVENTORY="${DEST_INVENTORY:-$REPO_ROOT/ansible-playbooks/inventory.ini}"
ENVIRONMENT="${ENVIRONMENT:-development}"

# shellcheck source=scripts/lib/output_mode.sh
source "$REPO_ROOT/scripts/lib/output_mode.sh"

log() { log_detail "[inventory] $*"; }
log_error() { printf '[inventory] %s\n' "$*" >&2; }

if [[ ! -d "$TF_DIR" ]]; then
  log "SKIP: Terraform directory not found: $TF_DIR"
  exit 0
fi

if [[ ! -f "$GEN_SCRIPT" ]]; then
  log_error "ERROR: generate_inventory.sh not found at $GEN_SCRIPT"
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
  log_error "ERROR: terraform not in PATH"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_error "ERROR: jq not in PATH"
  exit 1
fi

cd "$TF_DIR"
if terraform workspace list 2>/dev/null | grep -qw "$ENVIRONMENT"; then
  terraform workspace select "$ENVIRONMENT" >/dev/null
  log "Terraform workspace: $ENVIRONMENT"
fi

if ! terraform output -json >/dev/null 2>&1; then
  log "SKIP: no Terraform outputs (run Terraform apply first)"
  exit 0
fi

bash "$GEN_SCRIPT"
if [[ ! -f "$TF_DIR/ansible_inventory.ini" ]]; then
  log_error "ERROR: $TF_DIR/ansible_inventory.ini was not generated"
  exit 1
fi

mkdir -p "$(dirname "$DEST_INVENTORY")"
cp -f "$TF_DIR/ansible_inventory.ini" "$DEST_INVENTORY"
log_verbose "[inventory] Wrote $DEST_INVENTORY (ansible_host = public IPs from Terraform)"
