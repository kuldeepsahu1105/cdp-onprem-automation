#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import subprocess
import sys
import yaml

root = Path(sys.argv[1])
tasks = yaml.safe_load(
    (root / "ansible-playbooks/common_tasks/ensure_python_psycopg2.yml").read_text()
)

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

print("psycopg2 discovery probe checks passed")
PY
