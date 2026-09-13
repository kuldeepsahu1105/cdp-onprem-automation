#!/usr/bin/env bash
# Jenkins: deploy (if needed) and run EC2 start/stop/describe on ipaserver only.
# Script on ipaserver: /root/{ENVIRONMENT}_cldr_ec2_strt_stp.sh (Ansible ec2_startstop_script_path from deployment_name_prefix).
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
export ANSIBLE_CONTROL_VIA_JENKINS="${ANSIBLE_CONTROL_VIA_JENKINS:-1}"
export ANSIBLE_CONTROLLER_OUTSIDE_VPC="${ANSIBLE_CONTROLLER_OUTSIDE_VPC:-true}"
# shellcheck source=jenkins/scripts/aws-credential-check.sh
source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
aws_apply_instance_role_if_enabled
# shellcheck source=jenkins/scripts/resolve-ansible-ssh-key.sh
source "$REPO_ROOT/jenkins/scripts/resolve-ansible-ssh-key.sh"
resolve_ansible_ssh_key
bash "$REPO_ROOT/jenkins/scripts/apply-ansible-group-vars.sh"
bash "$REPO_ROOT/jenkins/scripts/ansible-connectivity-preflight.sh"

OPERATION="${EC2_STARTSTOP_OPERATION:-describe}"
GROUPS="${EC2_STARTSTOP_GROUPS:-}"
ENVIRONMENT_TAG="${EC2_STARTSTOP_ENVIRONMENT:-${ENVIRONMENT:-development}}"
NON_INTERACTIVE="${EC2_STARTSTOP_NON_INTERACTIVE:-1}"

[[ -f ansible-playbooks/inventory.ini ]] || { echo "ERROR: ansible-playbooks/inventory.ini missing"; exit 1; }

if ! command -v ansible-playbook >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/jenkins/scripts/ensure-ansible.sh"
fi

LOG_FILE="$LOG_DIR/ec2-startstop-${BUILD_NUMBER:-local}.log"
log() { printf '[ec2-startstop] %s\n' "$*" | tee -a "$LOG_FILE"; }

log "operation=${OPERATION} environment=${ENVIRONMENT_TAG} groups=${GROUPS:-'(none)'} non_interactive=${NON_INTERACTIVE}"

# shellcheck source=scripts/lib/jenkins_log_pipe.sh
source "$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh"

PRIVATE_KEY="${ANSIBLE_PRIVATE_KEY:-}"
if [[ -z "$PRIVATE_KEY" ]]; then
  # shellcheck source=scripts/lib/ansible_env.sh
  source "$REPO_ROOT/scripts/lib/ansible_env.sh"
  PRIVATE_KEY="$(resolve_private_key "$REPO_ROOT/ansible-playbooks")"
fi

set -o pipefail
jenkins_log_pipe "$LOG_FILE" ansible-playbook \
  -i "$REPO_ROOT/ansible-playbooks/inventory.ini" \
  "$REPO_ROOT/ansible-playbooks/37_run_ipaserver_ec2_startstop.yml" \
  --private-key "$PRIVATE_KEY" \
  --limit ipaserver \
  -e "ec2_startstop_operation=${OPERATION}" \
  -e "ec2_startstop_groups=${GROUPS}" \
  -e "ec2_startstop_environment=${ENVIRONMENT_TAG}" \
  -e "ec2_startstop_non_interactive=${NON_INTERACTIVE}"

log "EC2 start/stop automation completed"
