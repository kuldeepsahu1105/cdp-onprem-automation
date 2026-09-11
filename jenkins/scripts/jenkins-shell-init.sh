#!/usr/bin/env bash
# Shared Jenkins sh-step setup: disable xtrace noise, default quiet output.

set +x 2>/dev/null || true

export OUTPUT_MODE="${OUTPUT_MODE:-quiet}"
export LOG_DIR="${LOG_DIR:-${REPO_ROOT:-${WORKSPACE:-.}}/jenkins/artifacts}"

_jenkins_init_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${_jenkins_init_repo}/scripts/lib/output_mode.sh" ]]; then
  # shellcheck source=scripts/lib/output_mode.sh
  source "${_jenkins_init_repo}/scripts/lib/output_mode.sh"
fi
