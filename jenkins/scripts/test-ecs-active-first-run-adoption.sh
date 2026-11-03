#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
role_tasks = root / "ansible-playbooks/roles/ecs/tasks"
group_vars = yaml.safe_load(
    (root / "ansible-playbooks/group_vars/all.yml").read_text()
)
assert group_vars["ecs_coredns_extended_verification_enabled"] is False
setup = yaml.safe_load((role_tasks / "setup_cluster.yml").read_text())
setup_by_name = {task.get("name"): task for task in setup}
phased = (
    role_tasks / "ecs_phased_cluster_install.yml"
).read_text()
assert "ecs_stage_coredns_bootstrap.yml" in phased
assert "ecs_reconcile_coredns.yml" in phased
assert "ecs_coredns_first_run_bootstrap: true" in phased
assert phased.index("ecs_stage_coredns_bootstrap.yml") < phased.index(
    "ecs_install_control_plane.yml"
) < phased.index(
    "ecs_reconcile_coredns.yml"
) < phased.index(
    "ecs_configure_cli_tools.yml"
) < phased.index(
    "ecs_wait_control_plane_first_run.yml"
) < phased.index(
    "Start ECS cluster services and roles"
)

coredns_tasks = yaml.safe_load(
    (role_tasks / "ecs_reconcile_coredns.yml").read_text()
)
coredns_by_name = {task.get("name"): task for task in coredns_tasks}
for task_name in (
    "Check for ECS node-local DNS configuration",
    "Build verified ECS node-local DNS forwarding policy",
    "Apply verified ECS node-local DNS forwarding policy",
    "Restart ECS node-local DNS after configuration change",
    "Wait for ECS node-local DNS rollout after configuration change",
):
    task = coredns_by_name[task_name]
    when = task["when"]
    conditions = when if isinstance(when, list) else [when]
    assert (
        "ecs_coredns_extended_verification_enabled | default(false) | bool"
        in conditions
    )

bootstrap = (
    role_tasks / "ecs_stage_coredns_bootstrap.yml"
)
bootstrap_text = bootstrap.read_text()
bootstrap_tasks = yaml.safe_load(bootstrap_text)
bootstrap_by_name = {task.get("name"): task for task in bootstrap_tasks}
stage = bootstrap_by_name[
    "Stage initial RKE2 CoreDNS forwarding policy before First Run"
]
assert stage["ansible.builtin.copy"]["dest"] == (
    "{{ ecs_rke2_coredns_helm_config_path }}"
)
manifest_text = stage["ansible.builtin.copy"]["content"].replace(
    "{{ ecs_coredns_bootstrap_forwarders | join(' ') }}",
    "10.0.0.10 10.0.0.11",
).replace(
    "{{ ecs_coredns_bootstrap_hosts_config | indent(20, true) }}",
    "                    10.0.0.20 cldr-mngr.cldr.internal.arpa\n"
    "                    10.0.0.30 console-cdp.apps.cldr.internal.arpa\n"
    "                    10.0.0.40 ipaserver.cldr.internal.arpa\n"
    "                    fallthrough",
)
manifest = yaml.safe_load(manifest_text)
assert manifest["kind"] == "HelmChartConfig"
assert manifest["metadata"] == {
    "name": "rke2-coredns",
    "namespace": "kube-system",
}
values = yaml.safe_load(manifest["spec"]["valuesContent"])
forward = next(
    plugin
    for plugin in values["servers"][0]["plugins"]
    if plugin["name"] == "forward"
)
assert forward["parameters"] == ". 10.0.0.10 10.0.0.11"
hosts = next(
    plugin
    for plugin in values["servers"][0]["plugins"]
    if plugin["name"] == "hosts"
)
assert "10.0.0.20 cldr-mngr.cldr.internal.arpa" in hosts["configBlock"]
assert "10.0.0.30 console-cdp.apps.cldr.internal.arpa" in hosts["configBlock"]
assert "10.0.0.40 ipaserver.cldr.internal.arpa" in hosts["configBlock"]
assert hosts["configBlock"].strip().endswith("fallthrough")
assert "/etc/resolv.conf" not in manifest["spec"]["valuesContent"]

reconcile_text = (role_tasks / "ecs_reconcile_coredns.yml").read_text()
assert "Require static ECS bootstrap DNS records in CoreDNS" in reconcile_text
assert '"hosts {"' in reconcile_text
assert "ecs_coredns_required_dns_records | to_json" in reconcile_text

active_read = setup_by_name["Read active ECS cluster commands"]
assert active_read["ansible.builtin.uri"]["url"].endswith(
    "/commands?view=full"
)
assert active_read["delegate_to"] == "{{ cm_cluster_module_delegate_to }}"

decision = setup_by_name["Determine whether phased ECS installation is required"]
decision_text = decision["ansible.builtin.set_fact"][
    "ecs_phased_install_required"
]
assert "existing_ecs_active_commands.json['items']" in decision_text

start = setup_by_name["Start existing ECS cluster services"]
assert "not (ecs_phased_install_required | bool)" in start["when"]

wrapper = (root / "ansible-playbooks/33_setup_ecs_cluster.yml").read_text()
assert "name: ecs" in wrapper
assert "tasks_from: setup_cluster" in wrapper
final_coredns = setup_by_name["Reconcile ECS CoreDNS forwarding order"]
assert final_coredns["vars"]["ecs_coredns_first_run_bootstrap"] is True
assert (
    "not (ecs_coredns_reconciled_this_run | default(false) | bool)"
    in final_coredns["when"]
)

install = yaml.safe_load(
    (role_tasks / "ecs_install_control_plane.yml").read_text()
)
install_by_name = {task.get("name"): task for task in install}
adopted_read = install_by_name[
    "Read active ECS cluster commands for adopted control plane"
]
assert adopted_read["ansible.builtin.uri"]["url"].endswith(
    "/commands?view=full"
)
assert adopted_read["when"] == "ecs_control_plane_existing | bool"

install_compat = (
    root / "ansible-playbooks/common_tasks/ecs_install_control_plane.yml"
).read_text()
assert "name: ecs" in install_compat
assert "tasks_from: ecs_install_control_plane" in install_compat

wait = yaml.safe_load(
    (role_tasks / "ecs_wait_control_plane_first_run.yml").read_text()
)
wait_by_name = {task.get("name"): task for task in wait}
active_wait = wait_by_name[
    "Wait for active CM commands during adopted ECS First Run"
]
assert active_wait["ansible.builtin.include_tasks"] == (
    "{{ playbook_dir }}/common_tasks/wait_cm_api_command.yml"
)
assert active_wait["loop_control"]["loop_var"] == (
    "ecs_active_control_plane_command"
)
assert active_wait["vars"]["cm_api_command_id"] == (
    "{{ ecs_active_control_plane_command.id }}"
)

active_wait_index = next(
    index for index, task in enumerate(wait)
    if task.get("name")
    == "Wait for active CM commands during adopted ECS First Run"
)
service_wait_index = next(
    index for index, task in enumerate(wait)
    if task.get("name")
    == "Wait for adopted ECS First Run services after CoreDNS repair"
)
assert active_wait_index < service_wait_index

wait_compat = (
    root / "ansible-playbooks/common_tasks/ecs_wait_control_plane_first_run.yml"
).read_text()
assert "name: ecs" in wait_compat
assert "tasks_from: ecs_wait_control_plane_first_run" in wait_compat

data_services = (
    role_tasks / "setup_data_services.yml"
).read_text()
assert "ecs_reconcile_coredns.yml" not in data_services
assert "ecs_data_services_verify_dns.yml" not in data_services

print("ECS active First Run adoption checks passed")
PY
