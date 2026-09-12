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

cd "$SCRIPT_DIR"
ansible_install_collections_if_needed "$SCRIPT_DIR/requirements.yml"
exec ansible-playbook "$@"
