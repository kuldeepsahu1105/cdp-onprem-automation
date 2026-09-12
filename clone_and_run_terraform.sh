#!/bin/bash

# How to run: OWNER=myname ENVIRONMENT=production ./run_terraform_wrapper.sh

# make sure aws credentials are set or if using sso then logged in to awscli.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo ""
    echo "================================================================="
    echo "            🚀 $(echo "$0": "$1") 🚀          "
    echo "================================================================="
    echo ""
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
        curl -fsSL "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_amd64.zip" -o terraform.zip
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
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
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
print_message "Loading deployment configuration..."
SCRIPTS_LIB="$(resolve_scripts_lib)"
# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
echo "✅ Loaded configuration from: ${TFVARS_LOADED_FROM}"

print_message "Verify environment name : '$ENVIRONMENT' is set from ${TFVARS_LOADED_FROM}"

cd $GIT_REPO_NAME/terraform-code/cloudera-pvc-terraform || exit 1

print_message "Initializing Terraform..."
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

print_message "Planning Terraform..."
terraform plan "${TF_VARS[@]}" -out=tfplan.out

print_message "Applying Terraform..."
echo "TF_DATA_DIR: $(pwd)"
ls -l terraform.tfstate* || true
echo
terraform apply -auto-approve tfplan.out

print_message "✅ Terraform provisioning complete!"

# ------------------------------
# 🧾 GENERATE INVENTORY
# ------------------------------
print_message "Running generate_inventory.sh..."
print_message "Generating Ansible inventory..."

# Resolve script's base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "SCRIPT_DIR is: $SCRIPT_DIR"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
echo "ROOT_DIR is: $ROOT_DIR"
GEN_SCRIPT="$ROOT_DIR/generate_inventory.sh"
echo "GEN_SCRIPT is: $GEN_SCRIPT"
ls -l $GEN_SCRIPT || true

if [ -f "$GEN_SCRIPT" ]; then
    # bash "$GEN_SCRIPT" > "$OUTPUT_FILE" 2>&1
    # bash "$GEN_SCRIPT" | tee "$OUTPUT_FILE"
    bash "$GEN_SCRIPT"
else
    echo "❌ Error: generate_inventory.sh not found at $GEN_SCRIPT"
    exit 1
fi

OUTPUT_FILE="ansible_inventory.ini"
# gen_inventory="./inventory.ini"
# cp $gen_inventory $OUTPUT_FILE
print_message "Inventory generated at: $OUTPUT_FILE"
cat "$OUTPUT_FILE"
print_message "Ansible inventory generation completed."
print_message "Please check the inventory.ini file for the generated Ansible inventory."

# ------------------------------
# Define source and destination paths
# ------------------------------
src_inventory="./$OUTPUT_FILE"
dest_inventory="../../ansible-playbooks/inventory.ini"
ansible_dir="../../ansible-playbooks"

# Check if inventory.ini exists in current directory
if [ -f "$src_inventory" ]; then
    echo "✅ Found inventory.ini in current directory."

    # Check if ansible directory exists
    if [ -d "$ansible_dir" ]; then
        echo "✅ Found Ansible directory: $ansible_dir"

        # Check if destination path is valid (redundant but safe)
        if [ -d "$(dirname "$dest_inventory")" ]; then
            cp -vf "$src_inventory" "$dest_inventory"
            # cp -vf "./inventory_public.ini" "$ansible_dir/"
            echo "📂 Copied $src_inventory to $dest_inventory"
            echo
        else
            echo "❌ Error: Destination directory $(dirname "$dest_inventory") not found."
            echo
            exit 1
        fi
    else
        echo "❌ Error: Ansible directory $ansible_dir not found."
        echo
        exit 1
    fi
else
    echo "❌ Error: inventory.ini not found in $(pwd)"
    echo
    exit 1
fi

# ------------------------------
# 🔐 PEM file check and copy
# ------------------------------
pem_file=$(find . -maxdepth 1 -type f \( -name "*.pem" \))
if [ -z "$pem_file" ]; then
    echo "❌ Error: No .pem or idrsa file found."
    echo
    # exit 1
else
    echo "✅ Found key file: $pem_file"
    # cp -vf "$pem_file" "$ansible_dir/$pem_file"
    # echo "📂 Copied $pem_file to $ansible_dir/$pem_file"

    cp -vf "$pem_file" "../../ansible-playbooks/$pem_file"
    cp -vf "$pem_file" "../../ansible-playbooks/sshkey.pem"
    echo "📂 Copied $pem_file to ../../ansible-playbooks/$pem_file"
    echo
fi
print_message "Terraform Infrastructure Creation Completed..."

# # ------------------------------

# #!/bin/bash

# set -e
# set -o pipefail

# print_message() {
#   echo ""
#   echo "================================================================="
#   echo "            🚀 $(echo $0: $1) 🚀          "
#   echo "================================================================="
#   echo ""
# }

# # ------------------------------
# # 🔧 OVERRIDABLE CONFIG SECTION
# # ------------------------------
# AWS_REGION="${AWS_REGION:-ap-southeast-1}"
# OWNER="${OWNER:-ksahu-ygulati}"
# ENVIRONMENT="${ENVIRONMENT:-development}"
# TERRAFORM_VERSION="${TERRAFORM_VERSION:-latest}"

# # ------------------------------
# # ✅ INSTALL TERRAFORM & AWS CLI
# # ------------------------------
# install_tools() {
#   print_message "Checking Terraform and AWS CLI..."

#   # Check Terraform
#   if ! command -v terraform &> /dev/null; then
#     print_message "Installing Terraform..."
#     if [[ "$OSTYPE" == "darwin"* ]]; then
#       brew tap hashicorp/tap
#       brew install hashicorp/tap/terraform
#     else
#       sudo apt-get update && sudo apt-get install -y unzip wget
#       LATEST_URL=$(curl -s https://api.github.com/repos/hashicorp/terraform/releases/latest | grep browser_download_url | grep linux_amd64.zip | cut -d '"' -f 4)
#       wget -q "$LATEST_URL" -O terraform.zip
#       unzip -o terraform.zip
#       sudo mv terraform /usr/local/bin/
#       rm -f terraform.zip
#     fi
#   fi

#   # Check AWS CLI
#   if ! command -v aws &> /dev/null; then
#     print_message "Installing AWS CLI..."
#     if [[ "$OSTYPE" == "darwin"* ]]; then
#       brew install awscli
#     else
#       curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
#       unzip awscliv2.zip
#       sudo ./aws/install
#       rm -rf awscliv2.zip aws/
#     fi
#   fi

#   echo "✅ Tools ready."
# }

# install_tools

# # ------------------------------
# # ✅ AWS CREDENTIALS CHECK
# # ------------------------------
# print_message "Checking AWS credentials..."
# if ! aws sts get-caller-identity &>/dev/null; then
#   echo "❌ AWS credentials not found or session expired. Run 'aws configure' or 'aws sso login'."
#   exit 1
# fi
# echo "✅ AWS credentials are valid."

# # ------------------------------
# # 📁 CLONE AND CD INTO REPO
# # ------------------------------
# print_message "Cloning repository if needed..."
# if [ ! -d "cdp-onprem-automation" ]; then
#   git clone https://github.com/kuldeepsahu1105/cdp-onprem-automation.git
# fi
# cd cdp-onprem-automation/terraform-code/cloudera-pvc-terraform || exit 1

# # ------------------------------
# # 🛠️ Terraform Workspace Handling
# # ------------------------------
# print_message "Setting up Terraform workspace: $ENVIRONMENT"
# if terraform workspace list | grep -qw "$ENVIRONMENT"; then
#   terraform workspace select "$ENVIRONMENT"
# else
#   terraform workspace new "$ENVIRONMENT"
# fi
