#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
group_vars = yaml.safe_load(
    (root / "ansible-playbooks/group_vars/all.yml").read_text()
)
tasks = yaml.safe_load(
    (
        root
        / "ansible-playbooks/roles/identity/tasks/freeipa_server.yml"
    ).read_text()
)
by_name = {task["name"]: task for task in tasks}

assert group_vars["ipa_server_packages_state"] == "latest"
assert group_vars["ipa_server_packages_override"] == []

effective = by_name["Resolve FreeIPA package specifications"]
assert "ipa_server_packages_override" in str(effective)
assert "freeipa_server_packages" in str(effective)

redhat = by_name["Install or update required FreeIPA packages on Red Hat"]
assert redhat["ansible.builtin.dnf"]["state"] == (
    "{{ ipa_server_packages_state | default('latest') }}"
)
assert "disablerepo" in redhat["ansible.builtin.dnf"]

debian = by_name["Install or update required FreeIPA packages on Debian"]
assert debian["ansible.builtin.apt"]["state"] == (
    "{{ ipa_server_packages_state | default('latest') }}"
)

upgrade = by_name["Upgrade configured FreeIPA server after package update"]
assert upgrade["ansible.builtin.command"] == "ipa-server-upgrade"
assert "ipa_server_packages_changed | bool" in upgrade["when"]
assert "ipa_server_configured_healthy | bool" in upgrade["when"]

modern = by_name["Require FreeIPA modern UI when explicitly requested"]
assert modern["when"] == (
    "ipa_server_require_modern_ui | default(false) | bool"
)

print("FreeIPA repository-latest and optional pinning checks passed")
PY
