#!/usr/bin/env bash
# Install Ansible on Jenkins agent when ansible-playbook is missing.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/validate-${BUILD_NUMBER:-local}.log}"

log() { printf '[ensure-ansible] %s\n' "$*" | tee -a "$LOG_FILE"; }
fail() { printf '[ensure-ansible] ERROR: %s\n' "$*" >&2 | tee -a "$LOG_FILE"; exit 1; }

export PATH="${HOME}/.local/bin:${PATH}"

if command -v ansible-playbook >/dev/null 2>&1; then
  log "OK ansible-playbook ($(/usr/bin/env ansible-playbook --version 2>&1 | head -1))"
  exit 0
fi

log "ansible-playbook not found — installing Ansible"

if command -v dnf >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    sudo dnf install -y python3-pip python3-devel gcc libffi-devel openssl-devel 2>&1 | tee -a "$LOG_FILE" || true
    if dnf list ansible 2>/dev/null | grep -q ansible; then
      sudo dnf install -y ansible 2>&1 | tee -a "$LOG_FILE" || true
    fi
  else
    log "sudo not available passwordless — trying pip install only"
  fi
elif command -v apt-get >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    sudo apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || true
    sudo apt-get install -y python3-pip python3-dev build-essential 2>&1 | tee -a "$LOG_FILE" || true
    if apt-cache show ansible >/dev/null 2>&1; then
      sudo apt-get install -y ansible 2>&1 | tee -a "$LOG_FILE" || true
    fi
  fi
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  if ! command -v pip3 >/dev/null 2>&1; then
    fail "pip3 not found — install python3-pip on the Jenkins agent or pre-install ansible"
  fi
  pip3 install --user 'ansible-core>=2.15,<3' 'ansible>=8,<10' 2>&1 | tee -a "$LOG_FILE"
  export PATH="${HOME}/.local/bin:${PATH}"
fi

command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook still missing after install attempt"
log "OK ansible-playbook installed ($(/usr/bin/env ansible-playbook --version 2>&1 | head -1))"

if ! python3 -c "import cm_client" 2>/dev/null; then
  log "Installing cm_client Python package (cloudera.cluster modules)"
  pip3 install --user cm_client 2>&1 | tee -a "$LOG_FILE" || log "WARN: cm_client pip install failed — Kerberos/CMS API playbooks may fail"
fi
