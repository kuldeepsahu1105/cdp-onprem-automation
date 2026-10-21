#!/usr/bin/env bash
# Validate user-supplied cluster/IPA domains for Ozone Netty hostname rules (HDDS-16034).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PYTHON="${PYTHON:-python3}"

args=(--user-set-only)

if [[ -n "${ANSIBLE_GROUP_VARS_YAML:-}" ]]; then
  args+=(--from-ansible-group-vars-yaml "$ANSIBLE_GROUP_VARS_YAML")
fi

if [[ -n "${ANSIBLE_GROUP_VARS_FILE:-}" && -f "${ANSIBLE_GROUP_VARS_FILE}" ]]; then
  args+=(--from-ansible-group-vars-file "$ANSIBLE_GROUP_VARS_FILE")
fi

TFVARS_FILE="${TFVARS_FILE:-}"
if [[ -z "$TFVARS_FILE" ]]; then
  if [[ -f "$REPO_ROOT/.tfvars.yaml" ]]; then TFVARS_FILE="$REPO_ROOT/.tfvars.yaml"
  elif [[ -f "$REPO_ROOT/.tfvars.yml" ]]; then TFVARS_FILE="$REPO_ROOT/.tfvars.yml"
  fi
fi
if [[ -n "$TFVARS_FILE" && -f "$TFVARS_FILE" ]]; then
  case "$TFVARS_FILE" in
    *.yaml|*.yml) args+=(--from-tfvars-yaml "$TFVARS_FILE") ;;
  esac
fi

exec "$PYTHON" "$REPO_ROOT/scripts/lib/validate_cluster_domain.py" "${args[@]}"
