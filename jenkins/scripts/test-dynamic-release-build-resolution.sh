#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - \
  "${repo_root}/ansible-playbooks/config.yml" \
  "${repo_root}/ansible-playbooks/group_vars/all.yml" \
  "${repo_root}/ansible-playbooks/common_tasks/mirror_internal_cm_rhel.yml" \
  "${repo_root}/ansible-playbooks/31_setup_base_cluster.yml" \
  "${repo_root}/ansible-playbooks/common_tasks/set_cm_mirror_facts.yml" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

import yaml

config_path, group_vars_path, mirror_path, base_cluster_path, mirror_facts_path = map(
    Path, sys.argv[1:]
)
expected = {
    "cm_version": "7.13.2.20000",
    "cdh_version": "7.3.2.20000",
    "ecs_pvc_ds_version": "1.5.5-h40000",
}
for path in (config_path, group_vars_path):
    values = yaml.safe_load(path.read_text())
    assert {key: values[key] for key in expected} == expected

mirror_tasks = yaml.safe_load(mirror_path.read_text())
tasks_by_name = {task.get("name"): task for task in mirror_tasks}
resolver = tasks_by_name[
    "Resolve Cloudera Manager RPM filenames from repository listing"
]
argv = resolver["ansible.builtin.command"]["argv"]
script = argv[argv.index("-c") + 1]
packages = [
    "cloudera-manager-agent",
    "cloudera-manager-daemons",
    "cloudera-manager-server",
    "cloudera-manager-server-db-2",
]
listing = "\n".join(
    f'<a href="{package}-7.13.2.20000-98765432.el9.x86_64.rpm">'
    for package in packages
)
result = subprocess.run(
    [
        sys.executable,
        "-c",
        script,
        "7.13.2.20000",
        "9",
        "x86_64",
        *packages,
    ],
    input=listing,
    text=True,
    capture_output=True,
    check=False,
)
assert result.returncode == 0, result.stderr
assert json.loads(result.stdout) == [
    f"{package}-7.13.2.20000-98765432.el9.x86_64.rpm"
    for package in packages
]

base_cluster_tasks = yaml.safe_load(base_cluster_path.read_text())[1]["tasks"]
selection = next(
    task for task in base_cluster_tasks
    if task.get("name")
    == "Select published CDH parcel versions for configured release"
)
selection_expression = selection["ansible.builtin.set_fact"][
    "base_cluster_cdh_parcel_versions_available"
]
assert "cdh_version.split('.')[-1]" in selection_expression

mirror_fact_tasks = yaml.safe_load(mirror_facts_path.read_text())
mirror_facts_by_name = {
    task.get("name"): task for task in mirror_fact_tasks
}
assert "Read configured CDH parcel manifest for internal mirror" in mirror_facts_by_name
mirror_selection = mirror_facts_by_name[
    "Select published CDH parcel file for internal mirror target"
]["ansible.builtin.set_fact"]["cdh_mirror_parcel_filenames_available"]
assert "cdh_version.split('.')[-1]" in mirror_selection
assert "cdh_parcel_os_suffix_effective" in mirror_selection

print("Dynamic CM and CDH build resolution checks passed")
PY
