#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe_file="$repo_root/ansible-playbooks/common_tasks/ecs_data_services_verify_dns.yml"

python3 - "$probe_file" <<'PY'
from pathlib import Path
import json
import subprocess
import sys
import yaml

path = Path(sys.argv[1])
text = path.read_text()

assert text.count("- ansible-dns-check\n") == 5
assert "ansible-dns-check-{{" not in text
assert "ecs_data_services_dns_verification_records | to_json" in text
assert "records = json.loads(sys.argv[4])" in text
assert "pending = {record[\"fqdn\"]: record for record in records}" in text
assert "RESOLV_CONF_BEGIN" in text
assert "ALL_PROBES_OK" in text
assert "socket.getaddrinfo(" in text
assert "family=socket.AF_INET" in text
assert "(connect_address, port)" in text
assert "NSLOOKUP_DIAGNOSTIC" in text
assert "loop: \"{{ ecs_data_services_dns_verification_records }}\"" in text
assert "ecs_data_services_dns_probe_phases.stdout == 'Succeeded'" in text

tasks = yaml.safe_load(path.read_text())
start = next(
    task for task in tasks
    if task.get("name") == "Start Data Services DNS verification pod"
)
argv = start["ansible.builtin.command"]["argv"]
script = argv[argv.index("-c") + 1]

success = subprocess.run(
    [
        sys.executable,
        "-c",
        script,
        "1",
        "0",
        "1",
        json.dumps([
            {
                "label": "Localhost",
                "fqdn": "localhost",
                "address": "127.0.0.1",
                "port": 0,
            }
        ]),
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert success.returncode == 0, success.stderr
assert "DNS_A_OK fqdn=localhost ipv4=127.0.0.1" in success.stdout
assert "ALL_PROBES_OK" in success.stdout

failure = subprocess.run(
    [
        sys.executable,
        "-c",
        script,
        "1",
        "0",
        "1",
        json.dumps([
            {
                "label": "Wrong localhost",
                "fqdn": "localhost",
                "address": "192.0.2.1",
                "port": 0,
            }
        ]),
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert failure.returncode == 1
assert "PROBE_FAILED host=localhost expected=192.0.2.1" in failure.stderr

print("Single-pod Data Services DNS probe checks passed")
PY
