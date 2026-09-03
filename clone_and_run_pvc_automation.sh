#!/usr/bin/env bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REPO_NAME="cdp-onprem-automation"
GIT_REPO_URL="https://github.com/kuldeepsahu1105/$GIT_REPO_NAME.git"
GIT_BRANCH="main"

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

print_message() {
    echo ""
    echo "================================================================="
    echo "            🚀 $(basename "$0"): $1 🚀          "
    echo "================================================================="
    echo ""
}

print_message "Checking and setting up repository..."
if [ -d "$GIT_REPO_NAME" ]; then
    echo "Repository already exists. Pulling latest changes..."
    (cd "$GIT_REPO_NAME" && git fetch origin && git checkout "$GIT_BRANCH" && git pull origin "$GIT_BRANCH")
    echo
else
    echo "Cloning the repository..."
    git clone "$GIT_REPO_URL"
    (cd "$GIT_REPO_NAME" && git checkout "$GIT_BRANCH")
    echo
fi

SCRIPTS_LIB="$(resolve_scripts_lib)"
# shellcheck source=scripts/lib/portable.sh
source "$SCRIPTS_LIB/portable.sh"
ensure_bash

# shellcheck source=scripts/lib/load_tfvars.sh
source "$SCRIPTS_LIB/load_tfvars.sh"
set -a
load_tfvars
set +a
echo "Loaded configuration from: ${TFVARS_LOADED_FROM}"

echo "GIT_REPO_URL: $GIT_REPO_URL"

ANSIBLE_DIR="cdp-onprem-automation/ansible-test"

pem_file=""
while IFS= read -r -d '' keyfile; do
    pem_file="$keyfile"
    break
done < <(find "$ANSIBLE_DIR" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_rsa" -o -name "idrsa" \) -print0 2>/dev/null)

if [[ -z "$pem_file" ]]; then
    echo "Error: No .pem, id_rsa, or idrsa file found in $ANSIBLE_DIR."
    echo
    exit 1
fi

echo "Found key file: $pem_file"
echo

license_file=""
while IFS= read -r -d '' candidate; do
    license_file="$candidate"
    break
done < <(find . -maxdepth 1 -type f -iname "*license*" ! -iname "*info.txt" -print0 2>/dev/null)

if [[ -z "$license_file" ]]; then
    echo "Error: No license file found in the current directory."
    echo
    exit 1
elif [[ "$(basename "$license_file")" = "license.txt" ]]; then
    echo "license.txt already exists. Nothing to do."
    echo
else
    copy_file "$license_file" ./license.txt
    echo "Copied $license_file to license.txt"
    echo
fi

if [ -d "$ANSIBLE_DIR" ]; then
    echo "INFO: ansible-test directory exists at: $ANSIBLE_DIR"
    echo

    if [ ! -f "./license.txt" ]; then
        echo "ERROR: license.txt NOT found in current directory: $(pwd)"
        echo "ACTION: Ensure license.txt is present before running the script."
        echo
        exit 1
    else
        echo "INFO: Found license.txt in current directory."
        echo
    fi

    if ! has_glob_match "$ANSIBLE_DIR/*.pem"; then
        echo "ERROR: No .pem (SSH key) files found in: $ANSIBLE_DIR"
        echo "ACTION: Ensure SSH key (.pem) is present in ansible-test directory."
        echo
        exit 1
    else
        echo "INFO: Found .pem file(s) in ansible-test directory."
        echo
    fi

    echo "INFO: Copying license.txt to ansible-test directory..."
    copy_file "./license.txt" "$ANSIBLE_DIR/license.txt"
    echo

    echo "INFO: Setting correct permissions on .pem files (chmod 600)..."
    chmod 600 "$ANSIBLE_DIR"/*.pem
    echo

    echo "INFO: Changing directory to ansible-test..."
    echo
    cd "$ANSIBLE_DIR" || {
        echo "ERROR: Failed to change directory to $ANSIBLE_DIR"
        echo
        exit 1
    }

    echo "INFO: Pulling latest changes from Git..."
    git pull origin main

else
    echo "ERROR: ansible-test directory does not exist at: $ANSIBLE_DIR"
    exit 1
fi

echo ""

print_message "Executing pvc_setup.sh..."
chmod +x pvc_setup.sh
bash ./pvc_setup.sh
