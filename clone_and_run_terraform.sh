#!/usr/bin/env bash
# Provision AWS infrastructure for Cloudera PVC (Terraform wrapper).
#
# Usage:
#   ./clone_and_run_terraform.sh
#   DRY_RUN=true ./clone_and_run_terraform.sh
#   ./clone_and_run_terraform.sh --dry-run --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REPO_NAME="cdp-onprem-automation"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/kuldeepsahu1105/$GIT_REPO_NAME.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

HOST_MACHINE_ARCH="$(uname -m)"
case "$HOST_MACHINE_ARCH" in
  aarch64|arm64) TF_DL_ARCH="arm64"; AWSCLI_DL_ARCH="aarch64" ;;
  *) TF_DL_ARCH="amd64"; AWSCLI_DL_ARCH="x86_64" ;;
esac

resolve_scripts_lib_early() {
  if [[ -f "$SCRIPT_DIR/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$SCRIPT_DIR/scripts/lib"
  elif [[ -f "$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib/load_tfvars.sh" ]]; then
    printf '%s' "$SCRIPT_DIR/$GIT_REPO_NAME/scripts/lib"
  else
    printf ''
  fi
}

ensure_repo_checkout() {
  if [[ -f "$SCRIPT_DIR/scripts/lib/load_tfvars.sh" ]]; then
    return 0
  fi
  ui_step "Syncing repository checkout" "📥"
  local git_quiet=()
  if declare -F ui_git_quiet >/dev/null 2>&1 && ui_git_quiet; then
    git_quiet=(--quiet)
  fi
  if [[ -d "$GIT_REPO_NAME" ]]; then
    (cd "$GIT_REPO_NAME" && git fetch "${git_quiet[@]}" origin && git checkout "${git_quiet[@]}" "$GIT_BRANCH" && git pull "${git_quiet[@]}" origin "$GIT_BRANCH")
    ui_ok "Updated $GIT_REPO_NAME/ (branch: $GIT_BRANCH)"
  else
    git clone "${git_quiet[@]}" "$GIT_REPO_URL"
    (cd "$GIT_REPO_NAME" && git checkout "${git_quiet[@]}" "$GIT_BRANCH")
    ui_ok "Cloned $GIT_REPO_NAME/ (branch: $GIT_BRANCH)"
  fi
}

install_terraform() {
  ui_step "Terraform" "🏗️"
  if command -v terraform &>/dev/null; then
    ui_ok "$(terraform version | head -n1)"
    return
  fi
  local os
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" == "darwin" ]]; then
    brew tap hashicorp/tap
    if [[ "${TERRAFORM_VERSION:-latest}" == "latest" ]]; then
      brew install hashicorp/tap/terraform
    else
      brew install "hashicorp/tap/terraform@${TERRAFORM_VERSION}"
      brew link --overwrite --force "terraform@${TERRAFORM_VERSION}"
    fi
  elif [[ "$os" == "linux" ]]; then
    local version
    version="$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)"
    [[ "${TERRAFORM_VERSION:-latest}" != "latest" ]] && version="${TERRAFORM_VERSION}"
    curl -fsSL "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_${TF_DL_ARCH}.zip" -o terraform.zip
    unzip -q terraform.zip
    sudo mv terraform /usr/local/bin/
    rm -f terraform.zip
  else
    ui_err "Unsupported OS: $os"
    exit 1
  fi
  ui_ok "Installed $(terraform version | head -n1)"
}

install_awscli() {
  ui_step "AWS CLI" "☁️"
  if command -v aws &>/dev/null && [[ "$(aws --version 2>&1)" == *"aws-cli/2"* ]]; then
    ui_ok "$(aws --version 2>&1)"
    return
  fi
  local os
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" == "darwin" ]]; then
    brew install awscli
  elif [[ "$os" == "linux" ]]; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_DL_ARCH}.zip" -o awscliv2.zip
    unzip -q awscliv2.zip
    sudo ./aws/install --update
    rm -rf aws awscliv2.zip
  else
    ui_err "Unsupported OS: $os"
    exit 1
  fi
  ui_ok "$(aws --version 2>&1)"
}

install_jq() {
  ui_step "jq" "🔧"
  if command -v jq &>/dev/null; then
    ui_ok "$(jq --version)"
    return
  fi
  local os
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" == "darwin" ]]; then
    brew install jq
  elif [[ "$os" == "linux" ]]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y jq
    elif command -v yum &>/dev/null; then
      sudo yum install -y jq
    else
      ui_err "Could not install jq automatically"
      exit 1
    fi
  else
    ui_err "Unsupported OS: $os"
    exit 1
  fi
  ui_ok "$(jq --version)"
}

SCRIPTS_LIB="$(resolve_scripts_lib_early)"
if [[ -z "$SCRIPTS_LIB" ]]; then
  ensure_bash_fallback() { :; }
  ensure_repo_checkout_minimal() {
    if [[ ! -d "$GIT_REPO_NAME" ]]; then
      git clone "$GIT_REPO_URL"
      (cd "$GIT_REPO_NAME" && git checkout "$GIT_BRANCH")
    fi
  }
  ensure_repo_checkout_minimal
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
  wrapper_show_help_terraform
  exit 0
fi

wrapper_reexec_from_repo_if_needed "$SCRIPT_DIR" "${BASH_SOURCE[0]}" "$(basename "$0")" "${WRAPPER_REMAINING_ARGS[@]}"

REPO_ROOT="$(cd "$SCRIPTS_LIB/../.." && pwd)"
wrapper_print_identity "CDP On-Prem Terraform Provisioning" "$REPO_ROOT" "$SCRIPTS_LIB"

ui_section "Prerequisites" "🔧"
install_terraform
install_awscli
install_jq

ui_step "AWS credentials" "🔐"
if ! aws sts get-caller-identity &>/dev/null; then
  ui_err "AWS credentials not found or expired — run 'aws configure' or 'aws sso login'"
  exit 1
fi
ui_ok "Credentials valid"

ensure_repo_checkout

# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
ui_config_summary

if [[ -f "$REPO_ROOT/terraform-code/cloudera-pvc-terraform/main.tf" ]] || [[ -f "$REPO_ROOT/terraform-code/cloudera-pvc-terraform/terraform.tf" ]]; then
  TERRAFORM_DIR="$REPO_ROOT/terraform-code/cloudera-pvc-terraform"
  GEN_SCRIPT="$REPO_ROOT/generate_inventory.sh"
elif [[ -f "$SCRIPT_DIR/$GIT_REPO_NAME/terraform-code/cloudera-pvc-terraform/terraform.tf" ]]; then
  TERRAFORM_DIR="$SCRIPT_DIR/$GIT_REPO_NAME/terraform-code/cloudera-pvc-terraform"
  GEN_SCRIPT="$SCRIPT_DIR/$GIT_REPO_NAME/generate_inventory.sh"
else
  ui_err "Could not locate terraform-code/cloudera-pvc-terraform"
  exit 1
fi

ui_section "Terraform provisioning" "☁️"
ui_kv "Working directory" "$TERRAFORM_DIR" "📁"
ui_kv "Workspace" "${ENVIRONMENT}" "🌍"

ui_step "Terraform init" "⚙️"
cd "$TERRAFORM_DIR"
terraform init -input=false

ui_step "Select workspace: ${ENVIRONMENT}" "🗂️"
if terraform workspace list | grep -qw "${ENVIRONMENT}"; then
  terraform workspace select "${ENVIRONMENT}"
  ui_ok "Workspace '${ENVIRONMENT}' selected"
else
  terraform workspace new "${ENVIRONMENT}"
  ui_ok "Workspace '${ENVIRONMENT}' created"
fi

ui_step "Terraform plan" "📝"
terraform plan "${TF_VARS[@]}" -out=tfplan.out

case "${DRY_RUN:-false}" in
  1|true|yes|TRUE|YES|on|ON)
    ui_done "Dry run complete — plan only (no apply, no inventory copy)"
    exit 0
    ;;
esac

ui_step "Terraform apply" "🚀"
terraform apply -auto-approve tfplan.out
ui_done "Terraform provisioning complete"

ui_section "Ansible inventory" "📦"
if [[ -f "$GEN_SCRIPT" ]]; then
  bash "$GEN_SCRIPT"
else
  ui_err "generate_inventory.sh not found at $GEN_SCRIPT"
  exit 1
fi

OUTPUT_FILE="ansible_inventory.ini"
DEST_INVENTORY="$(cd "$REPO_ROOT/ansible-playbooks" && pwd)/inventory.ini"

if [[ -f "$OUTPUT_FILE" ]]; then
  cp -f "$OUTPUT_FILE" "$DEST_INVENTORY"
  ui_inventory_summary "$OUTPUT_FILE"
  ui_ok "Copied inventory to ansible-playbooks/inventory.ini"
else
  ui_err "ansible_inventory.ini not generated"
  exit 1
fi

pem_file="$(find . -maxdepth 1 -type f -name '*.pem' | head -1)"
if [[ -n "$pem_file" ]]; then
  cp -f "$pem_file" "$REPO_ROOT/ansible-playbooks/$(basename "$pem_file")"
  cp -f "$pem_file" "$REPO_ROOT/ansible-playbooks/sshkey.pem"
  ui_ok "Copied SSH key to ansible-playbooks/"
fi

ui_next_steps
