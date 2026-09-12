#!/usr/bin/env bash
# Write SSH + Cloudera Manager access details for Jenkins email (jenkins/artifacts/cm-access.txt).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/jenkins/artifacts}"
ANSIBLE_DIR="${REPO_ROOT}/ansible-playbooks"
ALL_YML="${ANSIBLE_DIR}/group_vars/all.yml"
OVERRIDE_YML="${ANSIBLE_DIR}/jenkins_override.yml"
INVENTORY="${INVENTORY:-$OUT_DIR/inventory.ini}"
[[ -f "$INVENTORY" ]] || INVENTORY="${ANSIBLE_DIR}/inventory.ini"
OUT_FILE="${OUT_DIR}/cm-access.txt"

read_group_var() {
  local key="$1" default="${2:-}"
  local val="" f line
  for f in "$ALL_YML" "$OVERRIDE_YML"; do
    [[ -f "$f" ]] || continue
    line="$(grep -E "^${key}:" "$f" 2>/dev/null | head -1 || true)"
    if [[ -n "$line" ]]; then
      val="$(printf '%s' "$line" | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")"
    fi
  done
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
}

inventory_host_ip() {
  local group="$1" host="" ip=""
  [[ -f "$INVENTORY" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[${group}\] ]]; then
      host=""
      continue
    fi
    if [[ "$line" =~ ^\[ ]]; then
      [[ -n "$host" ]] && break
      continue
    fi
    [[ "$line" =~ ^# ]] && continue
    [[ -z "${line// }" ]] && continue
    host="${line%% *}"
    ip=""
    for tok in $line; do
      if [[ "$tok" =~ ^ansible_host= ]]; then
        ip="${tok#ansible_host=}"
      fi
    done
    if [[ -n "$host" && -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done < "$INVENTORY"
  return 1
}

cm_phase_ran() {
  if [[ "${ANSIBLE_PHASES:-}" == *3* ]]; then
    return 0
  fi
  if [[ "${PIPELINE_STAGES:-}" == *CM_INSTALL* ]]; then
    return 0
  fi
  if compgen -G "${OUT_DIR}/ansible-${BUILD_NUMBER:-local}-phase3.log" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

mkdir -p "$OUT_DIR"
{
  echo "CDP Deployment — SSH & Cloudera Manager Access"
  echo "=============================================="
  echo "Build:       ${JOB_NAME:-local} #${BUILD_NUMBER:-0}"
  echo "Environment: ${ENVIRONMENT:-n/a}"
  echo "Timestamp:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo ""

  pem_file=""
  for candidate in "$OUT_DIR"/*.pem "$ANSIBLE_DIR"/sshkey.pem "$ANSIBLE_DIR"/*.pem; do
    [[ -f "$candidate" ]] && pem_file="$candidate" && break
  done

  ssh_user="$(read_group_var ansible_user ec2-user)"
  cm_ip="$(inventory_host_ip cldr-mngr || true)"

  echo "SSH access (EC2 instances)"
  echo "--------------------------"
  if [[ -n "$pem_file" ]]; then
    echo "Private key file: ${pem_file#${REPO_ROOT}/}"
    echo "                (attached to this email when collected)"
    echo "Key permissions: chmod 600 <pem-file>"
  else
    echo "Private key:     not found in jenkins/artifacts/ or ansible-playbooks/"
  fi
  echo "SSH user:        ${ssh_user}"
  if [[ -n "$cm_ip" ]]; then
    echo "Example (CM host): ssh -i <pem-file> ${ssh_user}@${cm_ip}"
  fi
  echo ""

  if [[ -z "$cm_ip" ]]; then
    echo "Cloudera Manager: cldr-mngr not found in inventory — CM access N/A"
  elif ! cm_phase_ran; then
    echo "Cloudera Manager UI"
    echo "-----------------"
    echo "CM install phase not run in this build — UI URL after CM_INSTALL:"
    echo "  http://${cm_ip}:$(read_group_var cm_http_port 7180)/"
  else
    cm_user="$(read_group_var cm_admin_user admin)"
    cm_pass="$(read_group_var cm_admin_pass admin)"
    cm_http="$(read_group_var cm_http_port 7180)"
    cm_https="$(read_group_var cm_https_port 7183)"
    cm_domain="$(read_group_var ipaserver_domain)"

    echo "Cloudera Manager UI"
    echo "-----------------"
    echo "HTTP URL:        http://${cm_ip}:${cm_http}/"
    echo "HTTPS URL:       https://${cm_ip}:${cm_https}/  (after Auto-TLS / phase 4)"
    if [[ -n "$cm_domain" ]]; then
      echo "CM hostname:     cldr-mngr.${cm_domain} (internal DNS when IPA/DNS configured)"
    fi
    echo ""
    echo "Cloudera Manager login"
    echo "--------------------"
    echo "Username:        ${cm_user}"
    echo "Password:        ${cm_pass}"
    echo ""
    echo "Notes"
    echo "-----"
    echo "- Default admin password is from group_vars/all.yml (or Jenkins ANSIBLE_GROUP_VARS_YAML overrides)."
    echo "- Change the admin password in CM UI after first login in production."
    echo "- Ensure your client IP is allowed in the cluster security group for ports 22, ${cm_http}, ${cm_https}."
  fi
} > "$OUT_FILE"

printf '[cm-access] Wrote %s\n' "$OUT_FILE"
