#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TASKS="$REPO_ROOT/ansible-playbooks/roles/cdh_base_cluster/tasks/setup_base_cluster.yml"

python3 - "$TASKS" <<'PY'
from pathlib import Path
import sys

tasks = Path(sys.argv[1]).read_text()
start = tasks.index(
    "- name: Determine whether post-start client configuration refresh is required"
)
end = tasks.index("- name: Reconcile stale Ranger configuration after startup", start)
refresh = tasks[start:end]

required_gates = (
    "base_cluster_first_run_required",
    "base_cluster_existing_restart_required",
    "base_cluster_required_config_changed",
    "base_cluster_partial_first_run_recovery_required",
    "base_cluster_ozone_ordered_recovery_required",
)
for gate in required_gates:
    assert gate in refresh, gate

assert "when: base_cluster_post_start_refresh_required | bool" in refresh
assert "existing_cluster.status == 200" not in refresh
assert "deployClientConfigsAndRefresh" in refresh

print("OK: clean base-cluster reruns skip post-start refresh")
PY
