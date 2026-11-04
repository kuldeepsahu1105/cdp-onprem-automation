#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe_file="$repo_root/ansible-playbooks/roles/ecs/tasks/ecs_data_services_verify_dns.yml"
group_vars_file="$repo_root/ansible-playbooks/group_vars/all.yml"
config_file="$repo_root/ansible-playbooks/config.yml"

python3 - "$probe_file" "$group_vars_file" "$config_file" <<'PY'
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
config = yaml.safe_load(Path(sys.argv[3]).read_text())

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
assert "(address, port)" in text
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
assert group_vars["ecs_data_services_refresh_service_discovery_dns"] is True
assert group_vars["ecs_service_discovery_namespace"] == "cdp"
assert group_vars["ecs_service_discovery_deployment_name"] == (
    "cdp-release-thunderhead-servicediscoverysimple"
)
assert group_vars["ecs_service_discovery_rollout_timeout"] == 300
assert group_vars["ecs_node_local_dns_reconcile"] is True
assert group_vars["ecs_node_local_dns_configmap_name"] == "node-local-dns"
assert group_vars["ecs_node_local_dns_daemonset_name"] == "node-local-dns"
assert config["ecs_coredns_forwarders"] == []

coredns_reconcile_path = path.parent / "ecs_reconcile_coredns.yml"
coredns_reconcile_tasks = yaml.safe_load(coredns_reconcile_path.read_text())
coredns_tasks_by_name = {
    task.get("name"): task for task in coredns_reconcile_tasks
}
assert "Require literal IP ECS CoreDNS upstreams" in coredns_tasks_by_name
direct_forwarders = coredns_tasks_by_name[
    "Resolve direct ECS CoreDNS forwarder candidates"
]["ansible.builtin.set_fact"]["ecs_coredns_direct_forwarder_candidates"]
assert "private_ip" in direct_forwarders
assert "default(" in direct_forwarders
assert "ansible_host" in direct_forwarders
assert direct_forwarders.count("ansible_host") == 1
assert "ad_dns_servers" in direct_forwarders
assert "extra_dns_nameservers" in direct_forwarders

corefile_build = coredns_tasks_by_name[
    "Build verified ECS CoreDNS forwarding policy"
]
corefile_argv = corefile_build["ansible.builtin.command"]["argv"]
corefile_script = corefile_argv[corefile_argv.index("-c") + 1]
assert "{{" not in corefile_script
assert "{%" not in corefile_script
platform_root = """.:53 {
    errors
    forward . /etc/resolv.conf {
        max_concurrent 1000
    }
}
"""
corefile_result = subprocess.run(
    [
        sys.executable,
        "-c",
        corefile_script,
        platform_root,
        "192.0.2.10 198.51.100.10",
        "identity.example",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert corefile_result.returncode == 0, corefile_result.stderr
assert platform_root.rstrip() in corefile_result.stdout
assert "identity.example:53 {" in corefile_result.stdout
assert "forward . 192.0.2.10 198.51.100.10" in corefile_result.stdout

non_breaking_space = "\u00a0"
live_identity_zone = (
    "identity.example:53 {\n"
    f"{non_breaking_space * 3}errors\n"
    f"{non_breaking_space * 3}cache 30\n"
    f"{non_breaking_space * 3}forward . 203.0.113.53\n"
    f"{non_breaking_space * 2}}}\n"
    ".:53 {\n"
    "  forward . /etc/resolv.conf\n"
    "}\n"
)
unicode_indent_update = subprocess.run(
    [
        sys.executable,
        "-c",
        corefile_script,
        live_identity_zone,
        "192.0.2.10 198.51.100.10",
        "identity.example",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert unicode_indent_update.returncode == 0, unicode_indent_update.stderr
assert unicode_indent_update.stdout.count("identity.example:53 {") == 1
assert "forward . 203.0.113.53" not in unicode_indent_update.stdout
assert (
    f"{non_breaking_space * 3}forward . 192.0.2.10 198.51.100.10"
    in unicode_indent_update.stdout
)

corefile_idempotent = subprocess.run(
    [
        sys.executable,
        "-c",
        corefile_script,
        corefile_result.stdout,
        "192.0.2.10 198.51.100.10",
        "identity.example",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert corefile_idempotent.returncode == 0, corefile_idempotent.stderr
assert corefile_idempotent.stdout == corefile_result.stdout
chart_corefile = platform_root + """
identity.example:53 {
    errors
    cache 30
    forward . 203.0.113.53
}
"""
chart_update = subprocess.run(
    [
        sys.executable,
        "-c",
        corefile_script,
        chart_corefile,
        "192.0.2.10 198.51.100.10",
        "identity.example",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert chart_update.returncode == 0, chart_update.stderr
assert platform_root.rstrip() in chart_update.stdout
assert chart_update.stdout.count("identity.example:53 {") == 1
assert "forward . 203.0.113.53" not in chart_update.stdout
assert "forward . 192.0.2.10 198.51.100.10" in chart_update.stdout

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
bootstrap = coredns_tasks_by_name[
    "Select authoritative ECS DNS upstreams during First Run bootstrap"
]
assert bootstrap["ansible.builtin.set_fact"][
    "ecs_coredns_forwarders_effective"
] == "{{ ecs_coredns_direct_forwarder_candidates }}"
assert (
    bootstrap["when"]
    == "ecs_coredns_first_run_bootstrap | default(false) | bool"
)
for task_name in (
    "Remove stale ECS DNS upstream probe pods",
    "Start direct ECS DNS upstream probes",
    "Wait for direct ECS DNS upstream probes",
    "Read direct ECS DNS upstream probe output",
    "Remove completed ECS DNS upstream probe pods",
):
    task = coredns_tasks_by_name[task_name]
    when = task["when"]
    conditions = when if isinstance(when, list) else [when]
    assert (
        "not (ecs_coredns_first_run_bootstrap | default(false) | bool)"
        in conditions
    )
bootstrap_kubectl = coredns_tasks_by_name[
    "Expose ECS kubectl in the system path during First Run"
]
assert bootstrap_kubectl["ansible.builtin.file"]["src"] == (
    "{{ ecs_coredns_kubectl_path }}"
)
assert bootstrap_kubectl["ansible.builtin.file"]["dest"] == (
    "{{ ecs_kubectl_install_path }}"
)
assert (
    bootstrap_kubectl["when"]
    == "ecs_coredns_first_run_bootstrap | default(false) | bool"
)

assert group_vars["ecs_kubectl_install_path"] == "/usr/bin/kubectl"
assert group_vars["ecs_k9s_install_path"] == "/usr/bin/k9s"
upstream_assert = coredns_tasks_by_name[
    "Require a verified ECS DNS upstream"
]
assert "selectattr('stdout', 'defined')" in (
    upstream_assert["ansible.builtin.assert"]["fail_msg"]
)
node_local_build = coredns_tasks_by_name[
    "Build verified ECS node-local identity-domain forwarding policy"
]
for task_name in (
    "Check for ECS node-local DNS configuration",
    "Build verified ECS node-local identity-domain forwarding policy",
    "Apply verified ECS node-local DNS forwarding policy",
    "Restart ECS node-local DNS after configuration change",
    "Wait for ECS node-local DNS rollout after configuration change",
):
    task = coredns_tasks_by_name[task_name]
    conditions = task.get("when", [])
    conditions = conditions if isinstance(conditions, list) else [conditions]
    assert not any(
        "ecs_coredns_extended_verification_enabled" in str(condition)
        for condition in conditions
    )
node_local_argv = node_local_build["ansible.builtin.command"]["argv"]
node_local_script = node_local_argv[node_local_argv.index("-c") + 1]
node_local_corefile = """.:53 {
    errors
    cache 30
    bind 169.254.25.10 192.0.2.53
    forward . __PILLAR__UPSTREAM__SERVERS__ {
        force_tcp
        }
    }
cluster.example:53 {
    errors
    cache {
        success 9984 30
        denial 9984 5
        }
    bind 169.254.25.10 192.0.2.53
    forward . __PILLAR__CLUSTER__DNS__ {
        force_tcp
        }
    }
in-addr.arpa:53 {
    bind 169.254.25.10 192.0.2.53
    forward . __PILLAR__CLUSTER__DNS__
    }
ip6.arpa:53 {
    bind 169.254.25.10 192.0.2.53
    forward . __PILLAR__CLUSTER__DNS__
    }
"""
node_local_result = subprocess.run(
    [
        sys.executable,
        "-c",
        node_local_script,
        node_local_corefile,
        "identity.example",
    ],
    check=False,
    capture_output=True,
    text=True,
)
assert node_local_result.returncode == 0, node_local_result.stderr
assert "cluster.example:53 identity.example:53 {" in node_local_result.stdout
assert "__PILLAR__UPSTREAM__SERVERS__" in node_local_result.stdout
assert node_local_result.stdout.count(
    "forward . __PILLAR__CLUSTER__DNS__"
) == 3
assert (
    node_local_result.stdout.replace(
        "cluster.example:53 identity.example:53 {",
        "cluster.example:53 {",
        1,
    )
    == node_local_corefile
)
node_local_idempotent_result = subprocess.run(
    [
        sys.executable,
        "-c",
        node_local_script,
        node_local_result.stdout,
        "identity.example",
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
probe_start = tasks_by_name["Start Data Services DNS verification pod"]
probe_argv = probe_start["ansible.builtin.command"]["argv"]
probe_script = probe_argv[probe_argv.index("-c") + 1]
assert "successes_required = int(sys.argv[6])" in probe_script
assert "for sample in range(1, successes_required + 1)" in probe_script
assert "HTTPS_OK" in probe_script
assert probe_argv[-1] == (
    "{{ ecs_data_services_dns_probe_successes_required | default(1) | int }}"
)
probe_success = tasks_by_name[
    "Require successful Data Services DNS verification pod"
]
record_results = tasks_by_name[
    "Require selected Data Services DNS records in successful output"
]
assert "loop" not in probe_success
assert record_results["loop"] == "{{ ecs_data_services_dns_verification_records }}"

refresh_path = path.parent / "ecs_refresh_service_discovery_dns.yml"
refresh_tasks = yaml.safe_load(refresh_path.read_text())
refresh_tasks_by_name = {
    task.get("name"): task for task in refresh_tasks
}
restart_task = refresh_tasks_by_name[
    "Refresh ECS Service Discovery DNS cache before Data Services provisioning"
]
restart_argv = restart_task["ansible.builtin.command"]["argv"]
assert "rollout" in restart_argv
assert "restart" in restart_argv
assert (
    "deployment/{{ ecs_service_discovery_deployment_name }}"
    in restart_argv
)
wait_task = refresh_tasks_by_name[
    "Wait for refreshed ECS Service Discovery deployment"
]
assert (
    "--timeout={{ ecs_service_discovery_rollout_timeout }}s"
    in wait_task["ansible.builtin.command"]["argv"]
)
for task in refresh_tasks:
    if "ansible.builtin.command" in task:
        assert task["delegate_to"] == "{{ groups[ecs_cluster_master_group][0] }}"
        assert task["connection"] == "ssh"

playbook_tasks = yaml.safe_load(
    (path.parent / "setup_data_services.yml").read_text()
)
playbook_task_names = [task.get("name") for task in playbook_tasks]
reconcile_index = playbook_task_names.index(
    "Reconcile CoreDNS before Data Services provisioning"
)
verify_index = playbook_task_names.index(
    "Verify Data Services DNS through Kubernetes pods"
)
refresh_index = playbook_task_names.index(
    "Refresh Service Discovery DNS state before Data Services provisioning"
)
credentials_index = playbook_task_names.index(
    "Load existing ECS automation API credentials"
)
assert reconcile_index < verify_index < refresh_index < credentials_index

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
        "printf 'Server:\\t192.0.2.53\\n"
        "Address:\\t192.0.2.53:53\\n\\n"
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
            "1",
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
            "1",
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
            "1",
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
