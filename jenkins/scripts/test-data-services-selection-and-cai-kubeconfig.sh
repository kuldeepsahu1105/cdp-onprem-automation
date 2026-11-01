#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
playbook = root / "ansible-playbooks/34_setup_ecs_data_services.yml"
playbook_text = playbook.read_text()

for service in ("cdw", "cde", "cai"):
    marker = f"- name: Provision {service.upper() if service != 'cai' else 'CAI'}"
    if service == "cdw":
        marker = "- name: Provision CDW"
    elif service == "cde":
        marker = "- name: Provision CDE"
    assert marker in playbook_text

assert "common_tasks/ecs_data_service_cdw_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: common_tasks/ecs_data_service_cdw_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: common_tasks/ecs_data_service_cde_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: common_tasks/ecs_data_service_cai_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: common_tasks/ecs_data_service_model_registry.yml" in playbook_text
assert "when: \"'model_registry' in (ecs_data_services_install_names | default([]))\"" in playbook_text

cai_files = list(
    (root / "ansible-playbooks/common_tasks").glob("ecs_data_service_cai*.yml")
)
combined = "\n".join(path.read_text() for path in cai_files)
assert "ecs_kubeconfig_path" not in combined
assert "ecs_coredns_kubeconfig_path" in combined

group_vars = yaml.safe_load(
    (root / "ansible-playbooks/group_vars/all.yml").read_text()
)
assert group_vars["ecs_coredns_kubeconfig_path"] == "/etc/rancher/rke2/rke2.yaml"

ozone_credentials = (
    root
    / "ansible-playbooks/common_tasks/ecs_model_registry_ozone_credentials.yml"
).read_text()
assert "/opt/cloudera/parcels/CDH/bin/ozone" in ozone_credentials
assert "*-ozone-STORAGE_CONTAINER_MANAGER" in ozone_credentials
assert 'HADOOP_CONF_DIR: "{{ ecs_ozone_conf_dir }}"' in ozone_credentials
assert 'OZONE_CONF_DIR: "{{ ecs_ozone_conf_dir }}"' in ozone_credentials
assert "failed_when: false" in ozone_credentials

print("Data Services selection and CAI kubeconfig checks passed")
PY
