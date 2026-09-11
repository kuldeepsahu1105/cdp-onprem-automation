#!/usr/bin/env bash
# Prepare holautosa persistent work directory (PSEAutomation pattern).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"

# shellcheck source=scripts/lib/holautosa_exec_dir.sh
source "$REPO_ROOT/scripts/lib/holautosa_exec_dir.sh"

prepare_holautosa_workdir
restore_ansible_artifacts_to_workspace
