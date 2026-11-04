#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe_file="$repo_root/ansible-playbooks/roles/ecs/tasks/ecs_data_services_verify_dns.yml"
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

coredns_reconcile = (
    path.parent / "ecs_reconcile_coredns.yml"
).read_text()
compat_coredns_reconcile = (
    path.parents[3] / "common_tasks/ecs_reconcile_coredns.yml"
).read_text()
assert "name: ecs" in compat_coredns_reconcile
assert "tasks_from: ecs_reconcile_coredns" in compat_coredns_reconcile
assert "Check for ECS node-local DNS configuration" in coredns_reconcile
assert "node-local DNS root server block was not found" in coredns_reconcile
assert "forward . \" + upstreams" in coredns_reconcile
assert 'r"(?P<footer>^[ \\t]*\\})"' in coredns_reconcile
assert "daemonset/{{ ecs_node_local_dns_daemonset_name }}" in coredns_reconcile

coredns_reconcile_tasks = yaml.safe_load(coredns_reconcile)
coredns_tasks_by_name = {
    task.get("name"): task for task in coredns_reconcile_tasks
}
assert "Extract applied ECS CoreDNS forward line" in coredns_tasks_by_name
assert "Report applied ECS CoreDNS forward line" in coredns_tasks_by_name
assert "Require literal IP ECS CoreDNS upstreams" in coredns_tasks_by_name
assert "Extract current ECS CoreDNS forward line" in coredns_tasks_by_name
assert "Report current ECS CoreDNS forward line" in coredns_tasks_by_name
assert coredns_tasks_by_name[
    "Extract current ECS CoreDNS forward line"
]["ansible.builtin.command"]["stdin"] == "{{ ecs_coredns_corefile.stdout }}"
assert coredns_tasks_by_name[
    "Extract applied ECS CoreDNS forward line"
]["ansible.builtin.command"]["stdin"] == (
    "{{ ecs_coredns_applied_corefile.stdout }}"
)
kubectl_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name") == "Check ECS kubectl binary"
)
api_wait_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name")
    == "Wait for ECS Kubernetes API before CoreDNS reconciliation"
)
api_require_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name")
    == "Require ECS Kubernetes API before CoreDNS reconciliation"
)
resolver_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name") == "Read ECS master resolver configuration"
)
probe_cleanup_index = next(
    index for index, task in enumerate(coredns_reconcile_tasks)
    if task.get("name") == "Remove stale ECS DNS upstream probe pods"
)
assert (
    kubectl_index
    < api_wait_index
    < api_require_index
    < resolver_index
    < probe_cleanup_index
)
api_wait = coredns_tasks_by_name[
    "Wait for ECS Kubernetes API before CoreDNS reconciliation"
]
assert api_wait["ansible.builtin.command"]["argv"][-1] == "--raw=/readyz"
assert api_wait["delegate_to"] == "{{ groups[ecs_cluster_master_group][0] }}"
assert api_wait["connection"] == "ssh"
assert api_wait["failed_when"] is False
assert api_wait["retries"] == (
    "{{ ecs_control_plane_install_poll_retries | default(240) }}"
)
assert api_wait["delay"] == (
    "{{ ecs_control_plane_install_poll_delay | default(15) }}"
)
api_require = coredns_tasks_by_name[
    "Require ECS Kubernetes API before CoreDNS reconciliation"
]
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
    "Build verified ECS node-local DNS forwarding policy"
]
api_require_conditions = "\n".join(api_require["ansible.builtin.assert"]["that"])
assert "ecs_coredns_kubernetes_api_ready.rc | int == 0" in api_require_conditions
assert (
    "ecs_coredns_kubernetes_api_ready.stdout | default('') | trim == 'ok'"
    in api_require_conditions
)

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

refresh_path = path.parent / "ecs_refresh_service_discovery_dns.yml"
refresh_tasks = yaml.safe_load(refresh_path.read_text())
refresh_tasks_by_name = {
    task.get("name"): task for task in refresh_tasks
}
rollout_restart_tasks = [
    task for task in refresh_tasks
    if "ansible.builtin.command" in task
    and "restart" in task["ansible.builtin.command"]["argv"]
]
assert len(rollout_restart_tasks) == 1
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

compat_refresh = (
    path.parents[3] / "common_tasks/ecs_refresh_service_discovery_dns.yml"
).read_text()
assert "name: ecs" in compat_refresh
assert "tasks_from: ecs_refresh_service_discovery_dns" in compat_refresh

setup_tasks = yaml.safe_load(
    (path.parent / "setup_data_services.yml").read_text()
)
setup_task_names = [task.get("name") for task in setup_tasks]
reconcile_index = setup_task_names.index(
    "Reconcile CoreDNS before Data Services provisioning"
)
verify_index = setup_task_names.index(
    "Verify Data Services DNS through Kubernetes pods"
)
refresh_index = setup_task_names.index(
    "Refresh Service Discovery DNS state before Data Services provisioning"
)
credentials_index = setup_task_names.index(
    "Load existing ECS automation API credentials"
)
assert reconcile_index < verify_index < refresh_index < credentials_index

freeipa_record = tasks_by_name[
    "Add FreeIPA to required Data Services DNS verification records"
]
freeipa_when = "\n".join(freeipa_record["when"])
assert "identity_provider_effective" in freeipa_when
assert "ecs_ldap_sync_effective" not in freeipa_when
assert "ecs_ldap_admin_user_effective" not in freeipa_when

freeipa_inventory = tasks_by_name[
    "Require FreeIPA inventory for Data Services DNS verification"
]
freeipa_inventory_when = "\n".join(freeipa_inventory["when"])
assert "identity_provider_effective" in freeipa_inventory_when
assert "ecs_ldap_sync_effective" not in freeipa_inventory_when
assert "ecs_ldap_admin_user_effective" not in freeipa_inventory_when

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
