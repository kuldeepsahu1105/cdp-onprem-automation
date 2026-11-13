#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TASKS="$REPO_ROOT/ansible-playbooks/roles/cdh_base_cluster/tasks/setup_base_cluster.yml"

python3 - "$TASKS" <<'PY'
from pathlib import Path
import sys

tasks = Path(sys.argv[1]).read_text()
start = tasks.index("- name: Verify Knox CDP proxy descriptors after cluster startup")
end = tasks.index("- name: Reconcile stale Ranger configuration after startup", start)
post_start = tasks[start:end]

assert "deployClientConfigsAndRefresh" not in post_start
assert "base_cluster_refresh_command" not in tasks

assert tasks.count("deployClientConfigsAndRefresh") == 2
assert "base_cluster_autotls_refresh_command" in tasks
assert "base_cluster_kerberos_refresh_command" in tasks

print("OK: generic post-start refresh removed; security refreshes remain")
PY
