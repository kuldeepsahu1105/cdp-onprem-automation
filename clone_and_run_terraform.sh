#!/bin/bash

# How to run: OWNER=myname ENVIRONMENT=production ./run_terraform_wrapper.sh

# make sure aws credentials are set or if using sso then logged in to awscli.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_MACHINE_ARCH="$(uname -m)"
case "$HOST_MACHINE_ARCH" in
  aarch64|arm64) TF_DL_ARCH="arm64"; AWSCLI_DL_ARCH="aarch64" ;;
  *) TF_DL_ARCH="amd64"; AWSCLI_DL_ARCH="x86_64" ;;
esac

if [[ -f "$SCRIPT_DIR/scripts/lib/ui.sh" ]]; then
  # shellcheck source=scripts/lib/ui.sh
  source "$SCRIPT_DIR/scripts/lib/ui.sh"
elif [[ -f "$SCRIPT_DIR/cdp-onprem-automation/scripts/lib/ui.sh" ]]; then
  # shellcheck source=cdp-onprem-automation/scripts/lib/ui.sh
  source "$SCRIPT_DIR/cdp-onprem-automation/scripts/lib/ui.sh"
fi

resolve_scripts_lib() {
    if [[ -f "$SCRIPT_DIR/scripts/lib/load_tfvars.sh" ]]; then
        printf '%s' "$SCRIPT_DIR/scripts/lib"
        return 0
    fi
    if [[ -f "$SCRIPT_DIR/cdp-onprem-automation/scripts/lib/load_tfvars.sh" ]]; then
        printf '%s' "$SCRIPT_DIR/cdp-onprem-automation/scripts/lib"
        return 0
    fi
    echo "Error: scripts/lib/load_tfvars.sh not found." >&2
    return 1
}

GIT_REPO_NAME="cdp-onprem-automation"
GIT_REPO_URL="https://github.com/kuldeepsahu1105/$GIT_REPO_NAME.git"
echo "GIT_REPO_URL: $GIT_REPO_URL"
GIT_BRANCH="main"

print_message() {
    if declare -F ui_step >/dev/null 2>&1; then
        ui_step "$1"
    else
        echo ""
        echo "=== $1 ==="
        echo ""
    fi
}

# ------------------------------
# 🛠 INSTALL TERRAFORM & AWSCLI V2 (macOS/Linux)
# ------------------------------
install_terraform() {
    print_message "Checking Terraform installation..."

    if command -v terraform &>/dev/null; then
        echo "✅ Terraform already installed: $(terraform version | head -n1)"
        return
    fi

    OS=$(uname | tr '[:upper:]' '[:lower:]')
    if [[ "$OS" == "darwin" ]]; then
        echo "🧰 Installing Terraform using Homebrew on macOS..."
        brew tap hashicorp/tap
        if [[ "$TERRAFORM_VERSION" == "latest" ]]; then
            brew install hashicorp/tap/terraform
        else
            brew install hashicorp/tap/terraform@$TERRAFORM_VERSION
            brew link --overwrite --force terraform@$TERRAFORM_VERSION
        fi
    elif [[ "$OS" == "linux" ]]; then
        echo "🧰 Installing Terraform $TERRAFORM_VERSION on Linux..."
        VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)
        [[ "$TERRAFORM_VERSION" != "latest" ]] && VERSION="$TERRAFORM_VERSION"
        curl -fsSL "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_${TF_DL_ARCH}.zip" -o terraform.zip
        unzip terraform.zip
        sudo mv terraform /usr/local/bin/
        rm -f terraform.zip
    else
        echo "❌ Unsupported OS: $OS"
        exit 1
    fi
    echo "✅ Terraform installed: $(terraform version | head -n1)"
}

install_awscli() {
    print_message "Checking AWS CLI installation..."

    if command -v aws &>/dev/null && [[ "$(aws --version 2>&1)" == *"aws-cli/2"* ]]; then
        echo "✅ AWS CLI v2 already installed: $(aws --version)"
        return
    fi

    OS=$(uname | tr '[:upper:]' '[:lower:]')
    if [[ "$OS" == "darwin" ]]; then
        echo "🧰 Installing AWS CLI v2 using Homebrew on macOS..."
        brew install awscli
    elif [[ "$OS" == "linux" ]]; then
        echo "🧰 Installing AWS CLI v2 on Linux..."
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_DL_ARCH}.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install --update
        rm -rf aws awscliv2.zip
    else
        echo "❌ Unsupported OS: $OS"
        exit 1
    fi
    echo "✅ AWS CLI installed: $(aws --version)"
}

install_jq() {
    print_message "Checking jq installation..."

    if command -v jq &>/dev/null; then
        echo "✅ jq already installed: $(jq --version)"
        return
    fi

    OS=$(uname | tr '[:upper:]' '[:lower:]')
    if [[ "$OS" == "darwin" ]]; then
        echo "🧰 Installing jq using Homebrew on macOS..."
        brew install jq
    elif [[ "$OS" == "linux" ]]; then
        echo "🧰 Installing jq on Linux..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y jq
        elif command -v yum &>/dev/null; then
            sudo yum install -y jq
        else
            echo "❌ Could not install jq automatically on Linux."
            exit 1
        fi
    else
        echo "❌ Unsupported OS: $OS"
        exit 1
    fi
    echo "✅ jq installed: $(jq --version)"
}

install_terraform
install_awscli
install_jq

# ------------------------------
# ✅ AWS CREDENTIALS CHECK
# ------------------------------
print_message "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ Error: AWS credentials not found or session expired. Run 'aws configure' or 'aws sso login'."
    exit 1
fi
echo "✅ AWS credentials are valid."

# ------------------------------
# 📁 CLONE AND CD INTO REPO
# ------------------------------
print_message "Checking Git installation..."
if ! command -v git &>/dev/null; then
    echo "❌ Git is not installed. Installing Git..."
    OS=$(uname | tr '[:upper:]' '[:lower:]')
    if [[ "$OS" == "darwin" ]]; then
        echo "🧰 Installing Git using Homebrew on macOS..."
        brew install git
    elif [[ "$OS" == "linux" ]]; then
        echo "🧰 Installing Git on Linux..."
        sudo apt-get update && sudo apt-get install -y git || sudo yum install -y git
    else
        echo "❌ Unsupported OS: $OS"
        exit 1
    fi
    echo "✅ Git installed: $(git --version)"
else
    echo "✅ Git already installed: $(git --version)"
fi

print_message "Cloning repository if needed..."

if [ ! -d "$GIT_REPO_NAME" ]; then
    git clone "$GIT_REPO_URL"
    cd $GIT_REPO_NAME || exit 1
    git checkout "$GIT_BRANCH"
    cd ..
else
    cd $GIT_REPO_NAME || exit 1
    git fetch origin
    git checkout "$GIT_BRANCH"
    git pull origin "$GIT_BRANCH"
    cd ..
fi

# ------------------------------
# 🔍 LOAD CONFIG (.tfvars.yaml | .tfvars.env)
# ------------------------------
print_message "Loading deployment configuration"
SCRIPTS_LIB="$(resolve_scripts_lib)"
# shellcheck source=scripts/lib/ui.sh
[[ -f "$SCRIPTS_LIB/ui.sh" ]] && source "$SCRIPTS_LIB/ui.sh"
# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
if declare -F ui_config_summary >/dev/null 2>&1; then
    ui_banner "CDP On-Prem Terraform Provisioning" "Environment: ${ENVIRONMENT}"
    ui_config_summary
else
    echo "Loaded configuration from: ${TFVARS_LOADED_FROM}"
fi

print_message "Verify environment: ${ENVIRONMENT}"

cd $GIT_REPO_NAME/terraform-code/cloudera-pvc-terraform || exit 1

print_message "Initializing Terraform"
terraform init

# ------------------------------
# 🔧 OVERRIDABLE CONFIG SECTION
# ------------------------------
# Section moved to .tfvars.env file

# ------------------------------
# 🌱 SET TERRAFORM WORKSPACE
# ------------------------------
print_message "Setting Terraform workspace to '${ENVIRONMENT}'..."
if terraform workspace list | grep -q "${ENVIRONMENT}"; then
    terraform workspace select "${ENVIRONMENT}"
else
    terraform workspace new "${ENVIRONMENT}"
fi

# ------------------------------
# 🧠 DYNAMIC VARS ASSEMBLY
# ------------------------------
# This contains all the variables that are passed to Terraform in order
# i.e. COMMON_VARS, VPC_VARS, SG_VARS, EIP_VARS, KEYPAIR_VARS, INSTANCE_GROUPS_VARS
# Section moved to .tfvars.env file

# ------------------------------
# 🚀 TERRAFORM EXECUTION
# ------------------------------

print_message "Planning Terraform"
terraform plan "${TF_VARS[@]}" -out=tfplan.out

case "${DRY_RUN:-false}" in
  1|true|yes|TRUE|YES|on|ON)
    ui_done "Terraform dry run complete (plan only — no apply)"
    exit 0
    ;;
esac

print_message "Applying Terraform"
terraform apply -auto-approve tfplan.out

if declare -F ui_done >/dev/null 2>&1; then
    ui_done "Terraform provisioning complete"
else
    print_message "Terraform provisioning complete"
fi

# ------------------------------
# 🧾 GENERATE INVENTORY
# ------------------------------
print_message "Generating Ansible inventory"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEN_SCRIPT="$ROOT_DIR/generate_inventory.sh"

if ui_verbose; then
    ui_info "GEN_SCRIPT: $GEN_SCRIPT"
fi

if [ -f "$GEN_SCRIPT" ]; then
    bash "$GEN_SCRIPT"
else
    ui_err "generate_inventory.sh not found at $GEN_SCRIPT"
    exit 1
fi

OUTPUT_FILE="ansible_inventory.ini"
src_inventory="./$OUTPUT_FILE"
dest_inventory="../../ansible-playbooks/inventory.ini"
ansible_dir="../../ansible-playbooks"

if declare -F ui_inventory_summary >/dev/null 2>&1; then
    ui_inventory_summary "$src_inventory"
fi

if [ -f "$src_inventory" ] && [ -d "$ansible_dir" ] && [ -d "$(dirname "$dest_inventory")" ]; then
    cp -f "$src_inventory" "$dest_inventory"
    ui_ok "Copied inventory to ${dest_inventory}"
else
    ui_err "Failed to copy inventory to ansible-playbooks/"
    exit 1
fi

pem_file=$(find . -maxdepth 1 -type f \( -name "*.pem" \))
if [ -n "$pem_file" ]; then
    cp -f "$pem_file" "../../ansible-playbooks/$pem_file"
    cp -f "$pem_file" "../../ansible-playbooks/sshkey.pem"
    ui_ok "Copied SSH key to ansible-playbooks/"
fi

if declare -F ui_next_steps >/dev/null 2>&1; then
    ui_next_steps
else
    print_message "Terraform infrastructure creation completed"
fi
