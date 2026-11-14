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
playbook = (
    root / "ansible-playbooks/33_setup_ecs_cluster.yml"
).read_text()
assert "Restore managed DNS resolver configuration on ECS hosts" in playbook
assert playbook.index("common_tasks/configure_resolv_conf.yml") < playbook.index(
    "tasks_from: setup_cluster"
)
assert "ecs_reconcile_coredns.yml" in phased
assert "ecs_coredns_first_run_bootstrap: true" in phased
assert phased.index("ecs_install_control_plane.yml") < phased.index(
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
assert "Build verified ECS node-local identity-domain forwarding policy" in (
    coredns_by_name
)

active_read = setup_by_name["Read active ECS cluster commands"]
assert active_read["ansible.builtin.uri"]["url"].endswith(
    "/commands?view=full"
)
assert active_read["delegate_to"] == "{{ cm_cluster_module_delegate_to }}"

control_planes_read = setup_by_name[
    "Read existing ECS control plane records for reporting"
]
assert control_planes_read["ansible.builtin.uri"]["url"].endswith(
    "/controlPlanes?view=full"
)
assert control_planes_read["when"] == "existing_ecs_cluster.status == 200"
cluster_report = setup_by_name["Report existing ECS cluster details"]
assert "Existing ECS cluster found; installation will adopt it." in str(
    cluster_report["ansible.builtin.debug"]["msg"]
)
assert "existing_ecs_active_commands.json['items']" in str(
    cluster_report["ansible.builtin.debug"]["msg"]
)
service_report = setup_by_name["Report existing ECS service details"]
assert service_report["loop"] == (
    "{{ existing_ecs_services.json['items'] | default([]) }}"
)
control_plane_report = setup_by_name[
    "Report existing ECS control plane details"
]
assert "item.dnsSuffix" in control_plane_report["ansible.builtin.debug"]["msg"]
assert "item.remoteRepoUrl" in control_plane_report["ansible.builtin.debug"]["msg"]

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
assert all(
    "ecs_coredns_reconciled_this_run" not in condition
    for condition in final_coredns["when"]
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
assert "ecs_reconcile_coredns.yml" in data_services
assert "ecs_data_services_verify_dns.yml" in data_services

print("ECS active First Run adoption checks passed")
PY
