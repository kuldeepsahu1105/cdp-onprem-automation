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
  if is_enabled "${REQUIRE_TERRAFORM:-false}" || is_enabled "${RUN_DESTROY_STACK:-false}"; then
    tools+=(terraform)
  fi
  if is_enabled "${REQUIRE_ANSIBLE:-false}" || is_enabled "${RUN_STARTSTOP_AUTOMATION:-false}" || should_validate "${VALIDATE_ANSIBLE_SYNTAX:-true}" "ANSIBLE_SYNTAX"; then
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
  # shellcheck source=jenkins/scripts/aws-credential-check.sh
  source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
  aws_cred_diagnose | tee -a "$LOG_FILE"
  aws_verify_caller_identity | tee -a "$LOG_FILE" || fail "AWS credentials invalid — see [aws-creds] hints above (instance role may be overridden by stale Jenkins AWS_* env vars)"
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
  log "  infra: vpc_mode=${VPC_MODE:-USE_DEFAULT} create_vpc=${CREATE_VPC:-false} sg_mode=${SG_MODE:-USE_EXISTING} create_new_sg=${CREATE_NEW_SG:-false}"
  log "  names: keypair=${KEYPAIR_NAME:-n/a} sg=${EXISTING_SG_NAME:-${SG_NAME:-n/a}}"

  if is_enabled "${REQUIRE_TERRAFORM:-false}"; then
    # shellcheck source=jenkins/scripts/aws-credential-check.sh
    source "$REPO_ROOT/jenkins/scripts/aws-credential-check.sh"
    aws_apply_instance_role_if_enabled
    # shellcheck source=jenkins/scripts/validate-aws-resources.sh
    source "$REPO_ROOT/jenkins/scripts/validate-aws-resources.sh"
    validate_aws_resources | tee -a "$LOG_FILE" || fail "AWS resource pre-check failed — fix key pair or security group in tfvars"
  fi
fi

INVENTORY="${REPO_ROOT}/ansible-playbooks/inventory.ini"
if is_enabled "${REQUIRE_INVENTORY:-false}" || should_validate "${VALIDATE_INVENTORY:-false}" "INVENTORY"; then
  [[ -f "$INVENTORY" ]] || fail "inventory.ini required but missing at $INVENTORY (run Terraform first or provide inventory)"
  log "OK inventory: $INVENTORY"
fi

destroy_stack_only=false
if is_enabled "${RUN_DESTROY_STACK:-false}" && ! is_enabled "${REQUIRE_TERRAFORM:-false}" && ! is_enabled "${REQUIRE_ANSIBLE:-false}"; then
  destroy_stack_only=true
fi

# Fast PyYAML parse (no inventory/ansible); catches broken when: list items before syntax-check.
if [[ "$destroy_stack_only" == true ]]; then
  log "Skipping Ansible YAML/contract checks (DESTROY_STACK-only build)"
elif command -v python3 >/dev/null 2>&1; then
  "$REPO_ROOT/jenkins/scripts/validate-ansible-yaml.sh" | tee -a "$LOG_FILE"
  "$REPO_ROOT/jenkins/scripts/validate-ansible-contracts.sh" 2>&1 | tee -a "$LOG_FILE"
else
  log "Skipping Ansible YAML parse (python3 not available)"
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
