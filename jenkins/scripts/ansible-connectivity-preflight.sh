#!/usr/bin/env bash
# Quick SSH reachability check before Ansible playbooks run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
INVENTORY="${INVENTORY:-$REPO_ROOT/ansible-playbooks/inventory.ini}"
SSH_KEY="${ANSIBLE_PRIVATE_KEY:-$REPO_ROOT/ansible-playbooks/sshkey.pem}"
SSH_TIMEOUT="${ANSIBLE_SSH_TIMEOUT:-15}"
SSH_RETRIES="${ANSIBLE_SSH_RETRIES:-3}"
SSH_RETRY_DELAY="${ANSIBLE_SSH_RETRY_DELAY:-10}"
MAX_HOSTS="${ANSIBLE_PREFLIGHT_MAX_HOSTS:-5}"

# RHEL AMIs often accept ec2-user before root SSH is ready; try explicit user first.
_ssh_users_for_preflight() {
  if [[ -n "${ANSIBLE_SSH_USER:-}" ]]; then
    printf '%s\n' "$ANSIBLE_SSH_USER"
    return 0
  fi
  printf '%s\n' ec2-user root
}

log() { printf '[ansible-preflight] %s\n' "$*"; }

if [[ ! -f "$INVENTORY" ]]; then
  log "ERROR: inventory missing: $INVENTORY"
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  log "ERROR: SSH key missing: $SSH_KEY"
  exit 1
fi
chmod 600 "$SSH_KEY" 2>/dev/null || true

agent_ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -n "$agent_ip" ]]; then
  log "Jenkins/agent egress IP: ${agent_ip} (must be in SG ALLOWED_CIDRS for port 22)"
fi

log "Inventory hosts (first ${MAX_HOSTS}):"
awk '
  /^\[/ { gsub(/[\[\]]/, "", $0); group=$0; next }
  /^[^#[:space:]]/ {
    split($0, a, /[ =]+/)
    host=a[1]
    for (i=2; i<=NF; i++) {
      if ($i ~ /^ansible_host=/) { split($i, b, "="); ip=b[2] }
    }
    if (ip != "") print "  " group ": " host " -> " ip
  }
' "$INVENTORY" | head -n "$MAX_HOSTS"

_ssh_probe() {
  local user="$1" ip="$2" attempt
  for attempt in $(seq 1 "$SSH_RETRIES"); do
    if ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      -o StrictHostKeyChecking=no \
      "${user}@${ip}" "echo ok" >/dev/null 2>&1; then
      return 0
    fi
    [[ "$attempt" -lt "$SSH_RETRIES" ]] && sleep "$SSH_RETRY_DELAY"
  done
  return 1
}

failed=0
checked=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  host="${line%% *}"
  ip="${line##* }"
  checked=$((checked + 1))
  host_ok=false
  used_user=""
  while IFS= read -r ssh_user; do
    [[ -z "$ssh_user" ]] && continue
    if _ssh_probe "$ssh_user" "$ip"; then
      host_ok=true
      used_user="$ssh_user"
      break
    fi
  done < <(_ssh_users_for_preflight)
  if [[ "$host_ok" == true ]]; then
    log "OK  ${host} (${ip}) user=${used_user}"
  else
    log "FAIL ${host} (${ip}) — SSH unreachable after ${SSH_RETRIES} attempt(s) per user (check SG port 22, PEM/keypair match, users tried: $(tr '\n' ' ' < <(_ssh_users_for_preflight)))"
    failed=$((failed + 1))
  fi
  [[ "$checked" -ge "$MAX_HOSTS" ]] && break
done < <(awk '
  /^[^#[:space:]]/ {
    host=$1
    ip=""
    for (i=2; i<=NF; i++) if ($i ~ /^ansible_host=/) { split($i, a, "="); ip=a[2] }
    if (ip != "") print host " " ip
  }
' "$INVENTORY")

if [[ "$failed" -gt 0 ]]; then
  log "ERROR: ${failed}/${checked} host(s) failed SSH preflight"
  log "Hint: inventory must use public IPs for off-VPC Jenkins; regenerate via regenerate-inventory-from-terraform.sh"
  log "Hint: add agent IP ${agent_ip:-<unknown>} to Jenkins ALLOWED_CIDRS when SG_MODE=CREATE_NEW"
  exit 1
fi

log "SSH preflight passed (${checked} host(s) checked)"
