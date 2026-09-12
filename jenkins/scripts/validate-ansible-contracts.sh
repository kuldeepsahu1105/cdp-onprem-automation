#!/usr/bin/env bash
# Heuristic checks for cross-task Ansible variable contracts (portal verify, CM API).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
exec python3 "$REPO_ROOT/jenkins/scripts/validate-ansible-contracts.py" "$@"
