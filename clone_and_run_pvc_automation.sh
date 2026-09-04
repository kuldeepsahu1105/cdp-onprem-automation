#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REPO_NAME="cdp-onprem-automation"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/kuldeepsahu1105/$GIT_REPO_NAME.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

WRAPPER_SHOW_HELP=false
WRAPPER_REMAINING_ARGS=()
wrapper_parse_common_args "$@"

resolve_scripts_lib_early() {
  if [[ -f "$SCRIPT_DIR/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$SCRIPT_DIR/scripts/lib"
  elif [[ -f "$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib"
  elif [[ -f "$SCRIPT_DIR/ansible-playbooks/../scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$(cd "$SCRIPT_DIR/ansible-playbooks/.." && pwd)/scripts/lib"
  else
    printf ''
  fi
}

SCRIPTS_LIB="$(resolve_scripts_lib_early)"

if [[ -z "$SCRIPTS_LIB" ]]; then
  if [[ -d "$GIT_REPO_NAME" ]]; then
    (cd "$GIT_REPO_NAME" && git fetch origin && git checkout "$GIT_BRANCH" && git pull origin "$GIT_BRANCH")
  else
    git clone "$GIT_REPO_URL"
    (cd "$GIT_REPO_NAME" && git checkout "$GIT_BRANCH")
  fi
  SCRIPTS_LIB="$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib"
fi

# shellcheck source=scripts/lib/portable.sh
source "$SCRIPTS_LIB/portable.sh"
# shellcheck source=scripts/lib/ansible_env.sh
source "$SCRIPTS_LIB/ansible_env.sh"
# shellcheck source=scripts/lib/ui.sh
source "$SCRIPTS_LIB/ui.sh"
# shellcheck source=scripts/lib/wrapper_info.sh
source "$SCRIPTS_LIB/wrapper_info.sh"

if [[ "${WRAPPER_SHOW_HELP:-false}" == "true" ]]; then
  wrapper_show_help_ansible
  exit 0
fi

wrapper_reexec_from_repo_if_needed "$SCRIPT_DIR" "${BASH_SOURCE[0]}" "$(basename "$0")" "${WRAPPER_REMAINING_ARGS[@]}"

REPO_ROOT="$(cd "$SCRIPTS_LIB/../.." && pwd)"
wrapper_print_identity "Cloudera PVC Ansible Deployment" "$REPO_ROOT" "$SCRIPTS_LIB"

# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
ui_config_summary

ui_step "Resolving Ansible playbooks directory"
ANSIBLE_DIR="$(resolve_ansible_playbooks_dir "$SCRIPT_DIR")"
ui_kv "Ansible directory" "$ANSIBLE_DIR"

pem_file="$(resolve_private_key "$ANSIBLE_DIR")"
ui_kv "SSH private key" "$pem_file"

if [[ "${DEPLOY_PHASE:-1}" =~ ^(3|cm|phase3|4|cluster|phase4|all|full)$ ]]; then
  license_file="$(resolve_license_file "$ANSIBLE_DIR")"
  if ! is_dry_run; then
    ensure_license_txt "$ANSIBLE_DIR" "$license_file"
  fi
  ui_kv "License file" "$license_file"
fi

cd "$ANSIBLE_DIR"

ui_step "Executing pvc_setup.sh (DEPLOY_PHASE=${DEPLOY_PHASE:-1}, CONTROL_MODE=${CONTROL_MODE:-auto}, DRY_RUN=${DRY_RUN:-false})"
chmod +x pvc_setup.sh
export DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
export CONTROL_MODE="${CONTROL_MODE:-auto}"
export DRY_RUN="${DRY_RUN:-false}"
bash ./pvc_setup.sh "${WRAPPER_REMAINING_ARGS[@]}"
