#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REPO_NAME="cdp-onprem-automation"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/kuldeepsahu1105/$GIT_REPO_NAME.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

print_message() {
    echo ""
    echo "================================================================="
    echo "            $(basename "$0"): $1"
    echo "================================================================="
    echo ""
}

SCRIPTS_LIB=""
if [[ -f "$SCRIPT_DIR/scripts/lib/load_tfvars.sh" ]]; then
    SCRIPTS_LIB="$SCRIPT_DIR/scripts/lib"
elif [[ -f "$SCRIPT_DIR/ansible-playbooks/../scripts/lib/load_tfvars.sh" ]]; then
    SCRIPTS_LIB="$(cd "$SCRIPT_DIR/ansible-playbooks/.." && pwd)/scripts/lib"
else
    print_message "Checking and setting up repository..."
    if [[ -d "$GIT_REPO_NAME" ]]; then
        echo "Repository already exists. Pulling latest changes..."
        (cd "$GIT_REPO_NAME" && git fetch origin && git checkout "$GIT_BRANCH" && git pull origin "$GIT_BRANCH")
    else
        echo "Cloning the repository..."
        git clone "$GIT_REPO_URL"
        (cd "$GIT_REPO_NAME" && git checkout "$GIT_BRANCH")
    fi
    SCRIPTS_LIB="$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib"
fi

# shellcheck source=scripts/lib/portable.sh
source "$SCRIPTS_LIB/portable.sh"
# shellcheck source=scripts/lib/ansible_env.sh
source "$SCRIPTS_LIB/ansible_env.sh"
ensure_bash

# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
echo "Loaded configuration from: ${TFVARS_LOADED_FROM:-manual}"

ANSIBLE_DIR="$(resolve_ansible_playbooks_dir "$SCRIPT_DIR")"
echo "Ansible directory: $ANSIBLE_DIR"

pem_file="$(resolve_private_key "$ANSIBLE_DIR")"
echo "Using SSH private key: $pem_file"

if [[ "${DEPLOY_PHASE:-1}" =~ ^(3|cm|phase3|4|cluster|phase4|all|full)$ ]]; then
  license_file="$(resolve_license_file "$ANSIBLE_DIR")"
  ensure_license_txt "$ANSIBLE_DIR" "$license_file"
fi

cd "$ANSIBLE_DIR"

print_message "Executing pvc_setup.sh (DEPLOY_PHASE=${DEPLOY_PHASE:-1})..."
chmod +x pvc_setup.sh
export DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
export CONTROL_MODE="${CONTROL_MODE:-auto}"
bash ./pvc_setup.sh
