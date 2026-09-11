#!/usr/bin/env bash
# Copy deployment artifacts into jenkins/artifacts for Jenkins archive/email.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$OUT_DIR"

log() { printf '[collect] %s\n' "$*"; }

copy_if_exists() {
  local src="$1" dest_name="${2:-$(basename "$1")}"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$OUT_DIR/$dest_name"
    log "copied: $dest_name"
  fi
}

# Inventory
copy_if_exists "$REPO_ROOT/ansible-playbooks/inventory.ini" "inventory.ini"

# SSH keys (Terraform may place PEM in terraform dir or ansible-playbooks)
for pem in "$REPO_ROOT/ansible-playbooks"/*.pem "$REPO_ROOT/terraform-code/cloudera-pvc-terraform"/*.pem; do
  [[ -f "$pem" ]] && copy_if_exists "$pem"
done
copy_if_exists "$REPO_ROOT/ansible-playbooks/sshkey.pem"

# Terraform plan detail (written when SHOW_TF_PLAN_OUTPUT=false)
copy_if_exists "$OUT_DIR/terraform-plan-${BUILD_NUMBER:-local}-detail.log" "terraform-plan-detail.log"
copy_if_exists "$OUT_DIR/terraform-init-${BUILD_NUMBER:-local}.log" "terraform-init.log"
copy_if_exists "$OUT_DIR/terraform-apply-${BUILD_NUMBER:-local}.log" "terraform-apply.log"

# Terraform outputs / state snippets (non-secret)
TF_DIR="$REPO_ROOT/terraform-code/cloudera-pvc-terraform"
copy_if_exists "$TF_DIR/terraform_output.json"
if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  jq -c '{outputs: .outputs, resources: [.resources[]? | {type, name, instances: [.instances[]? | {attributes: {public_ip: .attributes.public_ip, private_ip: .attributes.private_ip, tags: .attributes.tags}}]}]}' \
    "$TF_DIR/terraform.tfstate" > "$OUT_DIR/terraform-state-summary.json" 2>/dev/null \
    || cp -f "$TF_DIR/terraform.tfstate" "$OUT_DIR/terraform.tfstate"
  log "copied: terraform state summary"
fi

# Workshop / CM info files (if present locally)
for info in "$REPO_ROOT"/*info.txt "$REPO_ROOT/ansible-playbooks"/*info.txt; do
  [[ -f "$info" ]] && copy_if_exists "$info"
done

log "Artifacts collected in $OUT_DIR"
ls -la "$OUT_DIR"
