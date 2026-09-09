#!/usr/bin/env bash
# Jenkins validation: tools, AWS credentials, config file, optional inventory.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/validate-${BUILD_NUMBER:-local}.log}"
cd "$REPO_ROOT"

# shellcheck source=jenkins/scripts/validation-flags.sh
source "$REPO_ROOT/jenkins/scripts/validation-flags.sh"

log() { printf '[validate] %s\n' "$*" | tee -a "$LOG_FILE"; }
fail() { printf '[validate] ERROR: %s\n' "$*" >&2; exit 1; }

TFVARS_FILE="${TFVARS_FILE:-}"
if should_validate "${VALIDATE_TFVARS:-true}" "TFVARS"; then
  if [[ -z "$TFVARS_FILE" ]]; then
    if [[ -f .tfvars.yaml ]]; then TFVARS_FILE=".tfvars.yaml"
    elif [[ -f .tfvars.yml ]]; then TFVARS_FILE=".tfvars.yml"
    elif [[ -f .tfvars.env ]]; then TFVARS_FILE=".tfvars.env"
    else fail "No tfvars file found (.tfvars.yaml / .tfvars.env). Set TFVARS_FILE or add config to workspace."
    fi
  fi
  [[ -f "$TFVARS_FILE" ]] || fail "TFVARS_FILE not found: $TFVARS_FILE"
  export TFVARS_FILE
  log "Config file: $TFVARS_FILE"
else
  log "Skipping tfvars file check (VALIDATION_CHECKS)"
fi

if should_validate "${VALIDATE_TOOLS:-true}" "TOOLS"; then
  tools=(git jq aws python3)
  if is_enabled "${REQUIRE_TERRAFORM:-false}"; then
    tools+=(terraform)
  fi
  if is_enabled "${REQUIRE_ANSIBLE:-false}" || should_validate "${VALIDATE_ANSIBLE_SYNTAX:-true}" "ANSIBLE_SYNTAX"; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/jenkins/scripts/ensure-ansible.sh"
    export PATH="${HOME}/.local/bin:${PATH}"
    tools+=(ansible-playbook)
  fi
  for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
    log "OK tool: $tool ($(${tool} --version 2>&1 | head -1))"
  done
else
  log "Skipping tool checks"
fi

if should_validate "${VALIDATE_AWS:-true}" "AWS_CREDS"; then
  aws sts get-caller-identity >/dev/null || fail "AWS credentials invalid — configure Jenkins AWS credentials or run aws sso login on agent"
  log "OK AWS credentials"
else
  log "Skipping AWS credential check"
fi

if should_validate "${VALIDATE_TFVARS:-true}" "TFVARS" && [[ -n "${TFVARS_FILE:-}" ]]; then
  # shellcheck source=scripts/lib/load_tfvars.sh
  source "$REPO_ROOT/scripts/lib/load_tfvars.sh"
  set -a
  load_tfvars
  set +a

  [[ -n "${ENVIRONMENT:-}" ]] || fail "ENVIRONMENT not set after loading tfvars"
  [[ -n "${AWS_REGION:-}" ]] || fail "AWS_REGION not set after loading tfvars"
  [[ -n "${OWNER:-}" ]] || fail "OWNER not set after loading tfvars (set in tfvars or Jenkins OWNER parameter)"
  log "OK tfvars loaded (environment=${ENVIRONMENT}, region=${AWS_REGION}, owner=${OWNER})"
fi

INVENTORY="${REPO_ROOT}/ansible-playbooks/inventory.ini"
if is_enabled "${REQUIRE_INVENTORY:-false}" || should_validate "${VALIDATE_INVENTORY:-false}" "INVENTORY"; then
  [[ -f "$INVENTORY" ]] || fail "inventory.ini required but missing at $INVENTORY (run Terraform first or provide inventory)"
  log "OK inventory: $INVENTORY"
fi

if should_validate "${VALIDATE_ANSIBLE_SYNTAX:-true}" "ANSIBLE_SYNTAX"; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/jenkins/scripts/ensure-ansible.sh"
  export PATH="${HOME}/.local/bin:${PATH}"
  log "Ansible syntax check (ansible-playbooks/)"
  cd "$REPO_ROOT/ansible-playbooks"
  while IFS= read -r pb; do
    ansible-playbook --syntax-check "$pb" >/dev/null
    log "  syntax OK: $(basename "$pb")"
  done < <(find . -maxdepth 1 -name '[0-9]*.yml' -type f | sort)
else
  log "Skipping Ansible syntax check"
fi

log "Validation completed successfully"
