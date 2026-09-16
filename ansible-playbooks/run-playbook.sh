#!/usr/bin/env bash
# Run any playbook with the same Galaxy prerequisites as pvc_setup.sh / CI.
# Usage (from ansible-playbooks/):
#   ./run-playbook.sh 10_setup_deployment_portal.yml
#   ./run-playbook.sh -i inventory.ini 23_setup_postgres.yml -e key=val
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/ansible_env.sh
source "$REPO_ROOT/scripts/lib/ansible_env.sh"
# shellcheck source=../scripts/lib/ansible_group_vars_overrides.sh
source "$REPO_ROOT/scripts/lib/ansible_group_vars_overrides.sh"
# shellcheck source=../scripts/lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

cd "$SCRIPT_DIR"
ensure_ansible_cli
jenkins_prepare_log_output
ansible_configure_output
apply_ansible_group_vars_overrides "$REPO_ROOT" "$SCRIPT_DIR"
ansible_install_collections_if_needed "$SCRIPT_DIR/requirements.yml"

playbook_label="ansible-playbook"
for arg in "$@"; do
  if [[ "$arg" == *.yml || "$arg" == *.yaml ]]; then
    playbook_label="$arg"
    break
  fi
done

extra_args=()
if [[ -n "${ANSIBLE_GROUP_VARS_OVERRIDE_FILE:-}" ]]; then
  extra_args+=(-e "@${ANSIBLE_GROUP_VARS_OVERRIDE_FILE}")
fi

ui_playbook_header "$playbook_label" start
if ansible-playbook "$@" "${extra_args[@]}"; then
  ui_playbook_header "$playbook_label" end success
else
  rc=$?
  ui_playbook_header "$playbook_label" end failed
  exit "$rc"
fi
