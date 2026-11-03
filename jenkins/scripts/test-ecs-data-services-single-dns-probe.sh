#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe_file="$repo_root/ansible-playbooks/common_tasks/ecs_data_services_verify_dns.yml"
group_vars_file="$repo_root/ansible-playbooks/group_vars/all.yml"

python3 - "$probe_file" "$group_vars_file" <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import yaml

path = Path(sys.argv[1])
text = path.read_text()
group_vars = yaml.safe_load(Path(sys.argv[2]).read_text())

assert text.count("- ansible-dns-check\n") == 5
assert "ansible-dns-check-{{" not in text
assert "ecs_data_services_dns_verification_records | to_json" in text
assert "records = json.loads(sys.argv[4])" in text
assert "pending = {record[\"fqdn\"]: record for record in records}" in text
assert "RESOLV_CONF_BEGIN" in text
assert "ALL_PROBES_OK" in text
assert 'command = ["nslookup", "-type=A", query_host]' in text
assert "socket.getaddrinfo(" not in text
assert "ipaddress.IPv4Address(candidate)" in text
assert "COREDNS_ENDPOINT_FALLBACK_OK" in text
assert "ALL_PROBES_OK_WITH_COREDNS_ENDPOINT_FALLBACK" in text
assert "(connect_address, port)" in text
assert "NSLOOKUP_DIAGNOSTIC" in text
assert "loop: \"{{ ecs_data_services_dns_verification_records }}\"" in text
assert "ecs_data_services_dns_probe_phases.stdout == 'Succeeded'" in text
assert "'ALL_PROBES_OK' in ecs_data_services_dns_probe_logs.stdout_lines" in text
assert (
    "'ALL_PROBES_OK_WITH_COREDNS_ENDPOINT_FALLBACK'"
    in text
)
assert "ecs_data_services_dns_probe_attempts | default(3) | int" in text
assert "ecs_data_services_dns_probe_retry_delay | int" in text
assert group_vars["ecs_data_services_dns_probe_attempts"] == 3
assert group_vars["ecs_data_services_dns_probe_retry_delay"] > 30
assert group_vars["ecs_data_services_dns_probe_wait_retries"] == 24
assert group_vars["ecs_node_local_dns_reconcile"] is True
assert group_vars["ecs_node_local_dns_configmap_name"] == "node-local-dns"
assert group_vars["ecs_node_local_dns_daemonset_name"] == "node-local-dns"

coredns_reconcile_path = path.parent / "ecs_reconcile_coredns.yml"
coredns_reconcile_tasks = yaml.safe_load(coredns_reconcile_path.read_text())
coredns_tasks_by_name = {
    task.get("name"): task for task in coredns_reconcile_tasks
}

kubectl_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name") == "Check ECS kubectl binary"
)
api_wait_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name")
    == "Wait for ECS Kubernetes API before CoreDNS reconciliation"
)
probe_cleanup_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name") == "Remove stale ECS DNS upstream probe pods"
)
assert kubectl_index < api_wait_index < probe_cleanup_index
api_wait = coredns_tasks_by_name[
    "Wait for ECS Kubernetes API before CoreDNS reconciliation"
]
assert api_wait["ansible.builtin.command"]["argv"][-1] == "--raw=/readyz"
assert api_wait["delegate_to"] == "{{ groups[ecs_cluster_master_group][0] }}"
assert api_wait["connection"] == "ssh"
assert api_wait["failed_when"] is False
node_local_build = coredns_tasks_by_name[
    "Build verified ECS node-local DNS forwarding policy"
]
node_local_argv = node_local_build["ansible.builtin.command"]["argv"]
node_local_script = node_local_argv[node_local_argv.index("-c") + 1]
node_local_corefile = """.:53 {
    errors
    cache 30
    bind 169.254.25.10 172.43.0.10
    forward . __PILLAR__UPSTREAM__SERVERS__ {
        force_tcp
        }
    }
cluster.local:53 {
    errors
    cache {
        success 9984 30
        denial 9984 5
        }
    bind 169.254.25.10 172.43.0.10
    forward . __PILLAR__CLUSTER__DNS__ {
        force_tcp
        }
    }
in-addr.arpa:53 {
    bind 169.254.25.10 172.43.0.10
    forward . __PILLAR__CLUSTER__DNS__
    }
ip6.arpa:53 {
    bind 169.254.25.10 172.43.0.10
    forward . __PILLAR__CLUSTER__DNS__
    }
"""
node_local_result = subprocess.run(
    [
        sys.executable,
        "-c",
        node_local_script,
        node_local_corefile,
        "10.0.0.10 10.0.0.11",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert node_local_result.returncode == 0, node_local_result.stderr
assert "forward . 10.0.0.10 10.0.0.11 {" in node_local_result.stdout
assert "__PILLAR__UPSTREAM__SERVERS__" not in node_local_result.stdout
assert node_local_result.stdout.count(
    "forward . __PILLAR__CLUSTER__DNS__"
) == 3
assert (
    node_local_result.stdout.split("cluster.local:53", 1)[1]
    == node_local_corefile.split("cluster.local:53", 1)[1]
)
node_local_idempotent_result = subprocess.run(
    [
        sys.executable,
        "-c",
        node_local_script,
        node_local_result.stdout,
        "10.0.0.10 10.0.0.11",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert (
    node_local_idempotent_result.returncode == 0
), node_local_idempotent_result.stderr
assert node_local_idempotent_result.stdout == node_local_result.stdout

node_local_restart = coredns_tasks_by_name[
    "Restart ECS node-local DNS after configuration change"
]
assert (
    "daemonset/{{ ecs_node_local_dns_daemonset_name }}"
    in node_local_restart["ansible.builtin.command"]["argv"]
)
node_local_check_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name") == "Check for ECS node-local DNS configuration"
)
service_probe_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name")
    == "Verify required records through the CoreDNS Service and every ready replica"
)
assert node_local_check_index < service_probe_index

tasks = yaml.safe_load(path.read_text())
tasks_by_name = {task.get("name"): task for task in tasks}
probe_success = tasks_by_name[
    "Require successful Data Services DNS verification pod"
]
record_results = tasks_by_name[
    "Require selected Data Services DNS records in successful output"
]
assert "loop" not in probe_success
assert record_results["loop"] == "{{ ecs_data_services_dns_verification_records }}"

freeipa_task_names = [
    "Require FreeIPA inventory for Data Services DNS verification",
    "Resolve FreeIPA inventory host for DNS verification",
    "Add FreeIPA to required Data Services DNS verification records",
]
for task_name in freeipa_task_names:
    assert tasks_by_name[task_name]["when"] == [
        "identity_provider_effective | default('freeipa') == 'freeipa'"
    ]

ad_record = tasks_by_name[
    "Add Active Directory LDAP to required Data Services DNS verification records"
]
assert ad_record["when"] == [
    "identity_provider_effective | default('') == 'ad'"
]

start = next(
    task for task in tasks
    if task.get("name") == "Start Data Services DNS verification pod"
)
argv = start["ansible.builtin.command"]["argv"]
script = argv[argv.index("-c") + 1]

with tempfile.TemporaryDirectory() as temp_dir:
    nslookup = Path(temp_dir) / "nslookup"
    nslookup.write_text(
        "#!/bin/sh\n"
        "if [ \"${FAKE_SERVICE_FAIL:-0}\" = 1 ] && [ \"$#\" -lt 3 ]; then\n"
        "  echo '** server cannot find test name: NXDOMAIN'\n"
        "  exit 1\n"
        "fi\n"
        "printf 'Server:\\t172.43.0.10\\n"
        "Address:\\t172.43.0.10:53\\n\\n"
        "Name:\\t%s\\nAddress: 127.0.0.1\\n' \"$2\"\n"
    )
    nslookup.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = temp_dir + os.pathsep + env["PATH"]

    success = subprocess.run(
        [
            sys.executable,
            "-c",
            script,
            "1",
            "0",
            "5",
            json.dumps([
                {
                    "label": "Localhost",
                    "fqdn": "localhost",
                    "address": "127.0.0.1",
                    "port": 0,
                }
            ]),
            "172.42.1.96",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=env,
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
            "5",
            json.dumps([
                {
                    "label": "Wrong localhost",
                    "fqdn": "localhost",
                    "address": "192.0.2.1",
                    "port": 0,
                }
            ]),
            "172.42.1.96",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert failure.returncode == 1
    assert "PROBE_FAILED host=localhost expected=192.0.2.1" in failure.stderr

    fallback_env = env.copy()
    fallback_env["FAKE_SERVICE_FAIL"] = "1"
    fallback = subprocess.run(
        [
            sys.executable,
            "-c",
            script,
            "1",
            "0",
            "5",
            json.dumps([
                {
                    "label": "Fallback localhost",
                    "fqdn": "localhost",
                    "address": "127.0.0.1",
                    "port": 0,
                }
            ]),
            "172.42.1.96",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=fallback_env,
    )
    assert fallback.returncode == 0, fallback.stderr
    assert "COREDNS_ENDPOINT_FALLBACK_OK fqdn=localhost" in fallback.stdout
    assert "ALL_PROBES_OK_WITH_COREDNS_ENDPOINT_FALLBACK" in fallback.stdout

print("Single-pod Data Services DNS probe checks passed")
PY
