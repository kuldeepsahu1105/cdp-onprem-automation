#!/usr/bin/env bash
# Tear down AWS infrastructure (Terraform destroy) using the same tfvars/workspace as provision.
#
# Usage:
#   DESTROY_STACK_CONFIRM=true ./clone_and_run_terraform_destroy.sh
#   DRY_RUN=true ./clone_and_run_terraform_destroy.sh   # destroy plan only
#   ./clone_and_run_terraform_destroy.sh --dry-run --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REPO_NAME="cdp-onprem-automation"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/kuldeepsahu1105/$GIT_REPO_NAME.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

resolve_scripts_lib_early() {
  if [[ -f "$SCRIPT_DIR/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$SCRIPT_DIR/scripts/lib"
  elif [[ -f "$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib"
  else
    printf ''
  fi
}

SCRIPTS_LIB="$(resolve_scripts_lib_early)"
if [[ -z "$SCRIPTS_LIB" ]]; then
  if [[ ! -d "$GIT_REPO_NAME" ]]; then
    git clone "$GIT_REPO_URL"
    (cd "$GIT_REPO_NAME" && git checkout "$GIT_BRANCH")
  fi
  SCRIPTS_LIB="$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib"
fi

# shellcheck source=scripts/lib/portable.sh
source "$SCRIPTS_LIB/portable.sh"
# shellcheck source=scripts/lib/ui.sh
source "$SCRIPTS_LIB/ui.sh"
# shellcheck source=scripts/lib/wrapper_info.sh
source "$SCRIPTS_LIB/wrapper_info.sh"

WRAPPER_SHOW_HELP=false
WRAPPER_REMAINING_ARGS=()
wrapper_parse_common_args "$@"

if [[ "${WRAPPER_SHOW_HELP:-false}" == "true" ]]; then
  wrapper_show_help_terraform_destroy
  exit 0
fi

wrapper_reexec_from_repo_if_needed "$SCRIPT_DIR" "${BASH_SOURCE[0]}" "$(basename "$0")" "${WRAPPER_REMAINING_ARGS[@]}"

REPO_ROOT="$(cd "$SCRIPTS_LIB/../.." && pwd)"
wrapper_print_identity "CDP On-Prem Terraform Destroy" "$REPO_ROOT" "$SCRIPTS_LIB"

ui_step "AWS credentials" "🔐"
if ! aws sts get-caller-identity &>/dev/null; then
  ui_err "AWS credentials not found or expired — run 'aws configure' or 'aws sso login'"
  exit 1
fi
ui_ok "Credentials valid"

# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
ui_config_summary

if [[ -f "$REPO_ROOT/terraform-code/cloudera-pvc-terraform/main.tf" ]] || [[ -f "$REPO_ROOT/terraform-code/cloudera-pvc-terraform/terraform.tf" ]]; then
  TERRAFORM_DIR="$REPO_ROOT/terraform-code/cloudera-pvc-terraform"
elif [[ -f "$SCRIPT_DIR/$GIT_REPO_NAME/terraform-code/cloudera-pvc-terraform/terraform.tf" ]]; then
  TERRAFORM_DIR="$SCRIPT_DIR/$GIT_REPO_NAME/terraform-code/cloudera-pvc-terraform"
else
  ui_err "Could not locate terraform-code/cloudera-pvc-terraform"
  exit 1
fi

ui_section "Terraform destroy" "🧨"
ui_kv "Working directory" "$TERRAFORM_DIR" "📁"
ui_kv "Workspace" "${ENVIRONMENT}" "🌍"

# shellcheck source=scripts/lib/holautosa_exec_dir.sh
source "$SCRIPTS_LIB/holautosa_exec_dir.sh"
prepare_holautosa_workdir || true
restore_terraform_state_to_workspace "$TERRAFORM_DIR"

ui_step "Terraform init" "⚙️"
cd "$TERRAFORM_DIR"
# shellcheck source=scripts/lib/terraform_backend.sh
source "$SCRIPTS_LIB/terraform_backend.sh"
terraform_init_backend "$TERRAFORM_DIR"

ui_step "Select workspace: ${ENVIRONMENT}" "🗂️"
if terraform workspace list | grep -qw "${ENVIRONMENT}"; then
  terraform workspace select "${ENVIRONMENT}"
  ui_ok "Workspace '${ENVIRONMENT}' selected"
else
  ui_warn "Workspace '${ENVIRONMENT}' not found — nothing to destroy in state"
  exit 0
fi

# shellcheck source=scripts/lib/reconcile_terraform_resources.sh
source "$SCRIPTS_LIB/reconcile_terraform_resources.sh"
ui_step "Reconcile existing AWS key pair / security group" "🔄"
if reconcile_terraform_resources; then
  ui_ok "No Terraform variable changes from reconcile"
else
  ui_ok "Reconciled flags — reloading Terraform variables"
  # shellcheck source=scripts/lib/build_tf_vars.sh
  source "$SCRIPTS_LIB/build_tf_vars.sh"
fi

# shellcheck source=scripts/lib/terraform_destroy.sh
source "$SCRIPTS_LIB/terraform_destroy.sh"
terraform_run_destroy "$TERRAFORM_DIR" tfplan.destroy.out
