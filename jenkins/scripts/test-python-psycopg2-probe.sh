#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import subprocess
import sys
import yaml

root = Path(sys.argv[1])
shared_task_path = (
    root / "ansible-playbooks/common_tasks/ensure_python_psycopg2.yml"
)
tasks = yaml.safe_load(shared_task_path.read_text())

for role_task in (
    "roles/prereq_packages/tasks/main.yml",
    "roles/cm_install/tasks/install_postgresql.yml",
    "roles/cdh_base_cluster/tasks/setup_base_cluster.yml",
    "roles/cm_security/tasks/verify_cm_cms_reports_manager_db.yml",
):
    caller = (root / "ansible-playbooks" / role_task).read_text()
    assert (
        "{{ playbook_dir }}/common_tasks/ensure_python_psycopg2.yml" in caller
    ), f"{role_task} must import the authoritative shared psycopg2 task"

check = next(
    task
    for task in tasks
    if task.get("name") == "Check psycopg2 in each required Python interpreter"
)
probe = check["ansible.builtin.command"]["argv"][2]
assert 'find_spec("psycopg2")' in probe
assert "PSYCOPG2_MISSING" in probe
assert "PSYCOPG2_AVAILABLE=" in probe
assert check["failed_when"] is False

missing = subprocess.run(
    [sys.executable, "-S", "-c", probe],
    check=False,
    capture_output=True,
    text=True,
)
assert missing.returncode == 0
assert missing.stdout.strip() == "PSYCOPG2_MISSING"
assert missing.stderr == ""

guard = next(
    task
    for task in tasks
    if task.get("name")
    == "Require each Python interpreter to run before installing psycopg2"
)
conditions = "\n".join(guard["ansible.builtin.assert"]["that"])
assert "item.rc | int == 0" in conditions
assert "PSYCOPG2_MISSING" in conditions
assert "PSYCOPG2_AVAILABLE=" in conditions
assert "No module named" not in conditions

install = next(
    task
    for task in tasks
    if task.get("name")
    == "Install psycopg2-binary in each Python interpreter when required"
)
assert install["when"] == [
    "item.stdout | default('') == 'PSYCOPG2_MISSING'"
]

verify = next(
    task
    for task in tasks
    if task.get("name") == "Verify psycopg2 in each required Python interpreter"
)
assert "import psycopg2" in verify["ansible.builtin.command"]["argv"][2]
assert verify.get("failed_when") is None

print("psycopg2 discovery probe checks passed")
PY
