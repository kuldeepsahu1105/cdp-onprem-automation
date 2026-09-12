#!/usr/bin/env bash
# Prepare holautosa persistent work directory (PSEAutomation pattern).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"

# shellcheck source=scripts/lib/holautosa_exec_dir.sh
source "$REPO_ROOT/scripts/lib/holautosa_exec_dir.sh"

if ! prepare_holautosa_workdir; then
  printf '[holautosa-dir] FATAL: could not prepare %s\n' "${HOL_AUTO_EXEC_DIR:-/home/holautosa/HOL_AUTO_EXEC_DIR}" >&2
  exit 1
fi
restore_ansible_artifacts_to_workspace
