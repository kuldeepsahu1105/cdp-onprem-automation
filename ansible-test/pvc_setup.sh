#!/usr/bin/env bash

set -e          # Exit immediately if a command fails
set -o pipefail # Catch errors in pipes

# Identity provider: auto-detected from inventory (see 00_detect_identity.yml)
#   [ipaserver] has hosts -> FreeIPA full flow via 10_identity_setup.yml
#   no ipaserver + ad_kdc_host -> AD dependent flow only
echo "Identity provider mode: auto (detected from inventory)"
echo

# CM_VERSION=$CM_VERSION
echo "CM version to deploy is: $CM_VERSION"
echo
# CM_VERSION=7.13.2.0

FILE=$(ls *info.txt 2>/dev/null | head -n 1)

if [[ -z "$FILE" ]]; then
  echo "❌ No file ending with info.txt found"
  echo
  exit 1
fi

echo "📄 Using file: $FILE"
echo

CM_REPO_USERID=$(awk -F': *' '/^login:/ {print $2}' "$FILE")
CM_REPO_PASSWD=$(awk -F': *' '/^password:/ {print $2}' "$FILE")

export CM_REPO_USERID
export CM_REPO_PASSWD

# Confirm that variables are set
echo "Environment variables for cm_repo credentials set successfully."
echo "CM_REPO_USERNAME: $CM_REPO_USERID"
echo "CM_REPO_PASSWORD: $CM_REPO_PASSWD"
echo

# Function to print a fancy banner
print_banner() {
    echo "================================================================="
    echo "            🚀 CLOUDERA ON-PREMISE INSTALLATION SETUP 🚀          "
    echo "================================================================="
    echo ""
}

# Function to print completion message
print_completion() {
    echo ""
    echo "================================================================="
    echo " ✅ CLOUDERA INSTALLATION SETUP COMPLETED SUCCESSFULLY! 🎉       "
    echo "================================================================="
    echo
}

# Function to print a fancy banner
print_message() {
    echo ""
    echo "================================================================="
    echo "            🚀 $(echo $1) 🚀          "
    echo "================================================================="
    echo ""
}

# Print welcome banner
print_banner

echo "Updating system and installing dependencies..."
echo
# sudo yum update -y
# sudo yum install -y git dnf wget telnet net-tools bind-utils dnsutils iproute traceroute nc python3 python3-pip ansible
ansible-galaxy collection install -r requirements.yml
echo

echo "Verifying installations..."
git --version
python3 --version
pip3 --version
ansible --version
echo

# # Clone or update repository
# if [ -d "cdp-onprem-automation" ]; then
#     echo "Repository already exists. Pulling latest changes..."
#     cd cdp-onprem-automation
#     git reset --hard
#     git clean -fd
#     git pull origin main
# else
#     echo "Cloning the repository..."
#     git clone https://github.com/kuldeepsahu1105/cdp-onprem-automation.git
#     cd cdp-onprem-automation
# fi

# cd ansible-test/

# Find private key file
PRIVATE_KEY=$(find . -maxdepth 1 -type f \( -name "*.pem" -o -name "id_rsa" \) | head -n 1)

if [[ -z "$PRIVATE_KEY" ]]; then
    echo "ERROR!! No private key file found in the current directory to ssh into VMs. Please put the id_rsa or private key file before trying again. Exiting ..."
    echo
    exit 1
    # if [[ -f "$HOME/.ssh/id_rsa" ]]; then
    #     PRIVATE_KEY="$HOME/.ssh/id_rsa"
    #     echo "Using existing key from ~/.ssh/id_rsa"
    # else
    #     echo "No key found in ~/.ssh. Generating a new SSH key..."
    #     ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
    #     PRIVATE_KEY="$HOME/.ssh/id_rsa"
    #     echo "Generated new SSH key: $PRIVATE_KEY"
    # fi
fi

echo "Using private key: $PRIVATE_KEY"
chmod 600 "$PRIVATE_KEY"
ls -al "$PRIVATE_KEY"

# Update ansible_ssh_private_key_file in group_vars/all.yml
echo "Updating ansible_ssh_private_key_file in group_vars/all.yml..."
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "/^ansible_ssh_private_key_file:/c\\
ansible_ssh_private_key_file: $PRIVATE_KEY
" group_vars/all.yml
else
  sed -i "/^ansible_ssh_private_key_file:/c\\
ansible_ssh_private_key_file: $PRIVATE_KEY
" group_vars/all.yml
fi
echo

# Find license.txt file (exclude CM credential *info.txt files)
LICENSE_KEY=""
while IFS= read -r -d '' candidate; do
    LICENSE_KEY="$candidate"
    break
done < <(find . -maxdepth 1 -type f \( -iname "*license*" ! -iname "*info.txt" \) -print0 2>/dev/null)

if [[ -z "$LICENSE_KEY" ]]; then
    echo "ERROR!! No license key file found in the current directory to upload into CM. Please put the txt file before trying again. Exiting ..."
    echo
    exit 1
fi

echo "Using license key: $LICENSE_KEY"
ls -al "$LICENSE_KEY"
echo

# Ensure SSH allows password authentication and root login
# echo "Updating SSH configuration on IPAServer..."
# sudo sed -i 's/^#*PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
# sudo sed -i 's/^#*PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
# sudo systemctl restart sshd

echo "Updating SSH configuration prerequisites on all cluster hosts..."
# ansible all -i inventory.ini -m lineinfile -a "path=/etc/ssh/sshd_config regexp='^#*PasswordAuthentication' line='PasswordAuthentication yes'" --become
# ansible all -i inventory.ini -m lineinfile -a "path=/etc/ssh/sshd_config regexp='^#*PermitRootLogin' line='PermitRootLogin yes'" --become
# ansible all -i inventory.ini -m service -a "name=sshd state=restarted" --become
ansible-playbook 00_setup_ssh_preqs.yml --limit 'all:!ipaserver' --private-key="$PRIVATE_KEY"

# Function to print playbook execution message
run_playbook() {
    local playbook_name="$1"
    echo ""
    echo "------------------------------------------------------"
    echo "▶ Running playbook: $playbook_name"
    echo "------------------------------------------------------"

    ansible-playbook "$playbook_name" "$@"
    echo
}

# # Run all numbered playbooks in order
# for playbook in $(ls -1 *.yml | grep -E '^[0-9]+' | sort -V); do
#     echo "------------------------------------------------------"
#     echo "▶ Running playbook: $playbook"
#     echo "------------------------------------------------------"
#     ansible-playbook -i inventory.ini "$playbook"
# done

print_message "Running Ansible playbooks..."

print_message "Installing collection dependencies..."
run_playbook "01_install_collection.yml"

print_message "Setting hostname..."
run_playbook "02_set_hostname.yml"

print_message "Creating /etc/hosts entries..."
run_playbook "03_create_etc_hosts.yml"

# print_message "Setting up autossh..."
# run_playbook "04_setup_autossh.yml"

print_message "Disabling SELinux..."
run_playbook "05_disable_selinux.yml"

print_message "Running prerequisite setup..."
run_playbook "06_prereq_setup.yml"

print_message "Running additional prerequisite setup..."
run_playbook "07_prereq_setup_002.yml"

print_message "Running more prerequisite setup..."
run_playbook "08_prereq_setup_003.yml"

print_message "Verifying OS Prereqs..."
run_playbook "09_verify_os_prereqs.yml"

sleep 10

# print_message "Identity + DNS setup (auto-detect FreeIPA vs AD)..."
# run_playbook "10_identity_setup.yml"

# print_message "Setting up CM/CDH repositories..."
# Public (default): ansible-playbook 17_download_repos.yml -e cm_repo_username=... -e cm_repo_password=...
# Internal mirror: set cm_repo_source=internal in group_vars, then:
# run_playbook "16_setup_cm_repos.yml" -e cm_repo_username="$CM_REPO_USERID" -e cm_repo_password="$CM_REPO_PASSWD"

# print_message "Setting up postgres db..."
# run_playbook "18_setup_postgres.yml" -e cm_repo_username="$CM_REPO_USERID" -e cm_repo_password="$CM_REPO_PASSWD" -e cm_version="$CM_VERSION"

# print_message "Setting up (installing) CM server..."
# run_playbook "19_start_cm.yml" -e cm_repo_username="$CM_REPO_USERID" -e cm_repo_password="$CM_REPO_PASSWD"

# print_message "Verifying CM server is UP and get details..."
# run_playbook 20_verify_cm.yml -e "ansible_become=false"

# print_message "Uploading (installing) CM license..."
# run_playbook "21_setup_cm_license.yml" -e "ansible_become=false"

# Print completion banner
print_completion
