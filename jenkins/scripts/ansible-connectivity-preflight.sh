#!/usr/bin/env bash
# Quick SSH reachability check before Ansible playbooks run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
INVENTORY="${INVENTORY:-$REPO_ROOT/ansible-playbooks/inventory.ini}"
SSH_KEY="${ANSIBLE_PRIVATE_KEY:-$REPO_ROOT/ansible-playbooks/sshkey.pem}"
SSH_USER="${ANSIBLE_SSH_USER:-root}"
SSH_TIMEOUT="${ANSIBLE_SSH_TIMEOUT:-15}"
MAX_HOSTS="${ANSIBLE_PREFLIGHT_MAX_HOSTS:-5}"

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

failed=0
checked=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  host="${line%% *}"
  ip="${line##* }"
  checked=$((checked + 1))
  if ssh -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
    log "OK  ${host} (${ip})"
  else
    log "FAIL ${host} (${ip}) — SSH unreachable (check SG port 22, ansible_user=${SSH_USER}, key)"
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
