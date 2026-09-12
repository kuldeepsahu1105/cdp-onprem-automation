#!/usr/bin/env bash
# Jenkins/CLI: materialize CM license file from CM_LICENSE_CONTENT / CM_LICENSE_CONTENT_FILE.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=scripts/lib/ansible_env.sh
source "$REPO_ROOT/scripts/lib/ansible_env.sh"
materialize_cm_license_content "${REPO_ROOT}/ansible-playbooks"
