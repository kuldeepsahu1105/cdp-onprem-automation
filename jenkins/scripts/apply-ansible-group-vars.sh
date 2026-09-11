#!/usr/bin/env bash
# Jenkins/CLI entry: apply Ansible group_vars overrides before playbooks run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=scripts/lib/ansible_group_vars_overrides.sh
source "$REPO_ROOT/scripts/lib/ansible_group_vars_overrides.sh"
apply_ansible_group_vars_overrides "$REPO_ROOT"
