#!/usr/bin/env bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/portable.sh
source "$SCRIPT_DIR/scripts/lib/portable.sh"

ensure_bash
ensure_jq || exit 1

print_message() {
  echo ""
  echo "================================================================="
  echo "🧾 $(basename "$0"): $1"
  echo "================================================================="
  echo ""
}

print_message "Fetching Terraform output..."

TF_OUTPUT=$(terraform output -json)

if [[ -z "$TF_OUTPUT" ]]; then
  echo "❌ No Terraform output found."
  exit 1
fi

echo "✅ Terraform output fetched successfully."

# Debug keys
echo
echo "🔍 Available keys in public_ips:"
echo "$TF_OUTPUT" | jq -r '.public_ips.value | keys[]' 2>/dev/null || true

echo
echo "🔍 Available keys in private_ips:"
echo "$TF_OUTPUT" | jq -r '.private_ips.value | keys[]' 2>/dev/null || true

# ------------------------------
# Extract IPs (generic)
# ------------------------------
extract_ips() {
  local type=$1
  local pattern=$2

  echo "$TF_OUTPUT" | jq -r --arg pattern "$pattern" --arg type "$type" '
    .[$type].value
    | to_entries[]
    | select(.key | test($pattern))
    | .value
    | if type=="array" then .[] else . end
  ' 2>/dev/null || true
}

# ------------------------------
# Generate inventory section (with public + private IP)
# ------------------------------
generate_inventory_section() {
  local group=$1
  local pub_ips=("${!2}")
  local pvt_ips=("${!3}")

  echo "[$group]"

  if [[ ${#pub_ips[@]} -eq 0 ]]; then
    echo "# No hosts found for $group"
    echo
    return
  fi

  local index=1
  for i in "${!pub_ips[@]}"; do
    local pub_ip="${pub_ips[$i]}"
    local pvt_ip="${pvt_ips[$i]}"
    local hostname

    case "$group" in
      ipaserver) hostname="ipaserver" ;;
      cldr-mngr) hostname="cldr-mngr" ;;
      base-masters) hostname="pvcbase-master" ;;
      base-workers) hostname="pvcbase-worker${index}" ;;
      ecs-masters) hostname="pvcecs-master" ;;
      ecs-workers) hostname="pvcecs-worker${index}" ;;
    esac

    echo "$hostname ansible_host=$pub_ip private_ip=$pvt_ip cldr_hostname=$hostname"
    ((index++))
  done

  echo
}

# ------------------------------
# Generate single inventory
# ------------------------------
OUTPUT_FILE="ansible_inventory.ini"

print_message "Generating unified inventory → $OUTPUT_FILE"

{
  # Collect PUBLIC IPs
  ipa_pub=( $(extract_ips "public_ips" "^ipa_server") )
  mngr_pub=( $(extract_ips "public_ips" "^cldr_mngr") )
  base_m_pub=( $(extract_ips "public_ips" "^pvcbase_master") )
  base_w_pub=( $(extract_ips "public_ips" "^pvcbase_worker") )
  ecs_m_pub=( $(extract_ips "public_ips" "^pvcecs_master") )
  ecs_w_pub=( $(extract_ips "public_ips" "^pvcecs_worker") )

  # Collect PRIVATE IPs
  ipa_pvt=( $(extract_ips "private_ips" "^ipa_server") )
  mngr_pvt=( $(extract_ips "private_ips" "^cldr_mngr") )
  base_m_pvt=( $(extract_ips "private_ips" "^pvcbase_master") )
  base_w_pvt=( $(extract_ips "private_ips" "^pvcbase_worker") )
  ecs_m_pvt=( $(extract_ips "private_ips" "^pvcecs_master") )
  ecs_w_pvt=( $(extract_ips "private_ips" "^pvcecs_worker") )

  generate_inventory_section "ipaserver" ipa_pub[@] ipa_pvt[@]
  generate_inventory_section "cldr-mngr" mngr_pub[@] mngr_pvt[@]
  generate_inventory_section "base-masters" base_m_pub[@] base_m_pvt[@]
  generate_inventory_section "base-workers" base_w_pub[@] base_w_pvt[@]
  generate_inventory_section "ecs-masters" ecs_m_pub[@] ecs_m_pvt[@]
  generate_inventory_section "ecs-workers" ecs_w_pub[@] ecs_w_pvt[@]

} | tee "$OUTPUT_FILE"

echo "✅ Inventory generated: $OUTPUT_FILE"

print_message "Inventory generation completed successfully!"
