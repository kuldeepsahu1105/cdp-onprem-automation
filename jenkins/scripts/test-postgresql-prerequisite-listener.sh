#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
task_path = (
    root
    / "ansible-playbooks/roles/cm_security/tasks/assert_postgresql_installed.yml"
)
tasks = yaml.safe_load(task_path.read_text())
by_name = {task["name"]: task for task in tasks}

probe_hosts = by_name["Build PostgreSQL prerequisite TCP probe hosts"]
probe_hosts_text = str(probe_hosts)
for expected in (
    "postgres_ensure_cm_db_psql_host",
    "postgres_host_fqdn",
    "private_ip",
    "ansible_host",
    "127.0.0.1",
):
    assert expected in probe_hosts_text

listener = by_name["Verify PostgreSQL listener on database host"]
assert listener["delegate_to"] == "{{ postgres_inventory_host }}"
assert listener["ansible.builtin.wait_for"]["port"] == (
    "{{ postgres_port | default(5432) | int }}"
)
assert listener["failed_when"] is False

gate = by_name["Require PostgreSQL installation before downstream CM phases"]
gate_text = str(gate["ansible.builtin.assert"]["that"])
assert "postgresql_prerequisite_listener.results" in gate_text
assert "equalto', 'started" in gate_text
assert "postgresql_prerequisite_units.stdout_lines" not in gate_text
assert "postgresql_prerequisite_data.stdout_lines" not in gate_text

print("PostgreSQL prerequisite listener checks passed")
PY
