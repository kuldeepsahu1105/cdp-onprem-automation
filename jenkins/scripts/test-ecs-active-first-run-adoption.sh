#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
phased = (
    root
    / "ansible-playbooks/common_tasks/ecs_phased_cluster_install.yml"
).read_text()
setup = (root / "ansible-playbooks/33_setup_ecs_cluster.yml").read_text()
assert "Restore managed DNS resolver configuration on ECS hosts" in setup
assert setup.index("common_tasks/configure_resolv_conf.yml") < setup.index(
    "common_tasks/ecs_phased_cluster_install.yml"
)
assert "ecs_stage_coredns_bootstrap.yml" in phased
assert "ecs_reconcile_coredns.yml" in phased
assert "ecs_coredns_first_run_bootstrap: true" in phased
assert phased.index("ecs_stage_coredns_bootstrap.yml") < phased.index(
    "ecs_install_control_plane.yml"
) < phased.index(
    "ecs_reconcile_coredns.yml"
) < phased.index(
    "ecs_data_services_verify_dns.yml"
) < phased.index(
    "ecs_configure_cli_tools.yml"
) < phased.index(
    "ecs_wait_control_plane_first_run.yml"
) < phased.index(
    "Start ECS cluster services and roles"
)

playbook = yaml.safe_load(
    (root / "ansible-playbooks/33_setup_ecs_cluster.yml").read_text()
)
tasks = playbook[-1]["tasks"]
by_name = {task.get("name"): task for task in tasks}

active_read = by_name["Read active ECS cluster commands"]
assert active_read["ansible.builtin.uri"]["url"].endswith(
    "/commands?view=full"
)
assert active_read["delegate_to"] == "{{ cm_cluster_module_delegate_to }}"

decision = by_name["Determine whether phased ECS installation is required"]
decision_text = decision["ansible.builtin.set_fact"][
    "ecs_phased_install_required"
]
assert "existing_ecs_active_commands.json['items']" in decision_text

start = by_name["Start existing ECS cluster services"]
assert "not (ecs_phased_install_required | bool)" in start["when"]

final_coredns = by_name["Reconcile ECS CoreDNS forwarding order"]
assert final_coredns["vars"]["ecs_coredns_first_run_bootstrap"] is True
assert all(
    "ecs_coredns_reconciled_this_run" not in condition
    for condition in final_coredns["when"]
)

bootstrap = yaml.safe_load(
    (
        root
        / "ansible-playbooks/common_tasks/ecs_stage_coredns_bootstrap.yml"
    ).read_text()
)
bootstrap_by_name = {task.get("name"): task for task in bootstrap}
stage = bootstrap_by_name[
    "Stage persistent RKE2 CoreDNS forwarding policy before First Run"
]
manifest_text = stage["ansible.builtin.copy"]["content"].replace(
    "{{ ecs_coredns_bootstrap_forwarders | join(' ') }}",
    "10.0.0.10",
)
manifest = yaml.safe_load(manifest_text)
assert manifest["kind"] == "HelmChartConfig"
assert manifest["metadata"] == {
    "name": "rke2-coredns",
    "namespace": "kube-system",
}
values = yaml.safe_load(manifest["spec"]["valuesContent"])
root_forward = next(
    plugin
    for plugin in values["servers"][0]["plugins"]
    if plugin["name"] == "forward"
)
identity_forward = next(
    plugin
    for plugin in values["servers"][1]["plugins"]
    if plugin["name"] == "forward"
)
assert root_forward["parameters"] == ". /etc/resolv.conf"
assert values["servers"][1]["zones"] == [{"zone": "{{ cluster_domain }}"}]
assert identity_forward["parameters"] == ". 10.0.0.10"
assert values["nodelocal"]["extraClusterDomains"] == [
    "{{ cluster_domain }}"
]
assert "ecs_data_services_dns_probe_successes_required: 20" in phased

install = yaml.safe_load(
    (
        root
        / "ansible-playbooks/common_tasks/ecs_install_control_plane.yml"
    ).read_text()
)
install_by_name = {task.get("name"): task for task in install}
adopted_read = install_by_name[
    "Read active ECS cluster commands for adopted control plane"
]
assert adopted_read["ansible.builtin.uri"]["url"].endswith(
    "/commands?view=full"
)
assert adopted_read["when"] == "ecs_control_plane_existing | bool"

wait = yaml.safe_load(
    (
        root
        / "ansible-playbooks/common_tasks/ecs_wait_control_plane_first_run.yml"
    ).read_text()
)
wait_by_name = {task.get("name"): task for task in wait}
active_wait = wait_by_name[
    "Wait for active CM commands during adopted ECS First Run"
]
assert active_wait["ansible.builtin.include_tasks"] == "wait_cm_api_command.yml"
assert active_wait["loop_control"]["loop_var"] == (
    "ecs_active_control_plane_command"
)
assert active_wait["vars"]["cm_api_command_id"] == (
    "{{ ecs_active_control_plane_command.id }}"
)

print("ECS active First Run adoption checks passed")
PY
