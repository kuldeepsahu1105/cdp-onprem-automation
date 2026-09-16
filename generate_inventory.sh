#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/portable.sh
source "$SCRIPT_DIR/scripts/lib/portable.sh"
# shellcheck source=scripts/lib/ui.sh
source "$SCRIPT_DIR/scripts/lib/ui.sh"

ensure_bash
ensure_jq || exit 1

INVENTORY_SSH_MODE="${INVENTORY_SSH_MODE:-public}"
ANSIBLE_SSH_USER="${ANSIBLE_SSH_USER:-ec2-user}"

if [[ "$INVENTORY_SSH_MODE" != "public" && "$INVENTORY_SSH_MODE" != "private" && "$INVENTORY_SSH_MODE" != "bastion" ]]; then
  ui_err "INVENTORY_SSH_MODE must be public, private, or bastion (received: $INVENTORY_SSH_MODE)"
  exit 1
fi

ui_step "Fetch Terraform output" "📥"
TF_OUTPUT="$(terraform output -json)"

if [[ -z "$TF_OUTPUT" ]]; then
  ui_err "No Terraform output found"
  exit 1
fi
ui_ok "Terraform output fetched"

if ui_verbose; then
  ui_subsection "Terraform output keys" "🔍"
  while IFS= read -r key; do
    [[ -n "$key" ]] && ui_kv "public_ips" "$key" "🌐"
  done < <(echo "$TF_OUTPUT" | jq -r '.public_ips.value | keys[]' 2>/dev/null || true)
  while IFS= read -r key; do
    [[ -n "$key" ]] && ui_kv "private_ips" "$key" "🔒"
  done < <(echo "$TF_OUTPUT" | jq -r '.private_ips.value | keys[]' 2>/dev/null || true)
fi

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
    local inventory_name hostname ansible_target ssh_args=""

    case "$group" in
      ipaserver)
        inventory_name="ipa-node"
        hostname="ipaserver"
        ;;
      cldr-mngr)
        inventory_name="cm-node"
        hostname="cldr-mngr"
        ;;
      base-masters)
        inventory_name="pvcbase-master"
        hostname="pvcbase-master"
        ;;
      base-workers)
        inventory_name="pvcbase-worker${index}"
        hostname="pvcbase-worker${index}"
        ;;
      ecs-masters)
        inventory_name="pvcecs-master"
        hostname="pvcecs-master"
        ;;
      ecs-workers)
        inventory_name="pvcecs-worker${index}"
        hostname="pvcecs-worker${index}"
        ;;
    esac

    ansible_target="$pub_ip"
    if [[ "$INVENTORY_SSH_MODE" == "private" ]] ||
       [[ "$INVENTORY_SSH_MODE" == "bastion" && "$group" != "ipaserver" ]]; then
      if [[ -z "$pvt_ip" ]]; then
        ui_err "$INVENTORY_SSH_MODE inventory requires a private IP for $inventory_name"
        exit 1
      fi
      ansible_target="$pvt_ip"
    fi

    if [[ "$INVENTORY_SSH_MODE" == "bastion" && "$group" != "ipaserver" ]]; then
      if [[ -z "${BASTION_PUBLIC_IP:-}" ]]; then
        ui_err "Bastion inventory requires an IPAServer public IP"
        exit 1
      fi
      ssh_args=" ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyJump=${ANSIBLE_SSH_USER}@${BASTION_PUBLIC_IP}'"
    fi

    echo "$inventory_name ansible_host=$ansible_target private_ip=$pvt_ip public_ip=$pub_ip cldr_hostname=$hostname$ssh_args"
    ((index++))
  done

  echo
}

OUTPUT_FILE="ansible_inventory.ini"

ui_step "Generate inventory file" "📝"
ui_kv "Output file" "$OUTPUT_FILE" "📄"

{
  ipa_pub=( $(extract_ips "public_ips" "^ipa_server") )
  mngr_pub=( $(extract_ips "public_ips" "^cldr_mngr") )
  base_m_pub=( $(extract_ips "public_ips" "^pvcbase_master") )
  base_w_pub=( $(extract_ips "public_ips" "^pvcbase_worker") )
  ecs_m_pub=( $(extract_ips "public_ips" "^pvcecs_master") )
  ecs_w_pub=( $(extract_ips "public_ips" "^pvcecs_worker") )

  ipa_pvt=( $(extract_ips "private_ips" "^ipa_server") )
  mngr_pvt=( $(extract_ips "private_ips" "^cldr_mngr") )
  base_m_pvt=( $(extract_ips "private_ips" "^pvcbase_master") )
  base_w_pvt=( $(extract_ips "private_ips" "^pvcbase_worker") )
  ecs_m_pvt=( $(extract_ips "private_ips" "^pvcecs_master") )
  ecs_w_pvt=( $(extract_ips "private_ips" "^pvcecs_worker") )
  BASTION_PUBLIC_IP="${ipa_pub[0]:-}"

  generate_inventory_section "ipaserver" ipa_pub[@] ipa_pvt[@]
  generate_inventory_section "cldr-mngr" mngr_pub[@] mngr_pvt[@]
  generate_inventory_section "base-masters" base_m_pub[@] base_m_pvt[@]
  generate_inventory_section "base-workers" base_w_pub[@] base_w_pvt[@]
  generate_inventory_section "ecs-masters" ecs_m_pub[@] ecs_m_pvt[@]
  generate_inventory_section "ecs-workers" ecs_w_pub[@] ecs_w_pvt[@]
  echo "[deployment_portal_runtime]"
  echo "# Populated dynamically by portal and monitoring playbooks"
  echo

} | tee "$OUTPUT_FILE"

ui_ok "Inventory generated: ${OUTPUT_FILE}"
