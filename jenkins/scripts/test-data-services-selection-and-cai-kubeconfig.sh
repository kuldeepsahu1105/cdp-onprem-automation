#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import re
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
assert group_vars["ecs_cde_cpu_requests"] == "40"
assert group_vars["ecs_cde_memory_requests"] == "64Gi"
assert group_vars["ecs_cai_static_subdomain"] == "cai"
assert group_vars["ecs_model_registry_creator_crn"] == ""

ozone_credentials = (
    root
    / "ansible-playbooks/common_tasks/ecs_model_registry_ozone_credentials.yml"
).read_text()
ozone_tasks = yaml.safe_load(ozone_credentials)
assert "ansible.builtin.shell" not in ozone_credentials
assert "/usr/bin/ozone" in ozone_credentials
assert "/opt/cloudera/parcels/CDH/bin/ozone" in ozone_credentials
assert "/etc/ozone/conf/ozone-site.xml" in ozone_credentials
assert 'HADOOP_CONF_DIR: "{{ ecs_ozone_conf_dir }}"' in ozone_credentials
assert 'KRB5CCNAME: "FILE:{{ ecs_ozone_krb5_cache.path }}"' in ozone_credentials
assert 'OZONE_CONF_DIR: "{{ ecs_ozone_conf_dir }}"' in ozone_credentials
assert "failed_when: false" in ozone_credentials
assert "<redacted>" in ozone_credentials
ozone_task_names = [task.get("name") for task in ozone_tasks]
assert ozone_task_names.index(
    "Ozone S3 | Remove isolated Kerberos credential cache"
) < ozone_task_names.index("Ozone S3 | Require Kerberos authentication")
assert ozone_task_names.index(
    "Ozone S3 | Remove isolated Kerberos credential cache"
) < ozone_task_names.index("Ozone S3 | Require successful secret retrieval")
parsed_credentials_assert = next(
    task
    for task in ozone_tasks
    if task.get("name") == "Ozone S3 | Require parsed credentials"
)
assert parsed_credentials_assert["run_once"] is True
assert "run_once" not in parsed_credentials_assert["ansible.builtin.assert"]

def flatten_tasks(tasks):
    for task in tasks:
        yield task
        for section in ("block", "rescue", "always"):
            yield from flatten_tasks(task.get(section, []))

cai_tls_tasks = list(
    flatten_tasks(
        yaml.safe_load(
            (
                root
                / "ansible-playbooks/common_tasks/ecs_data_service_cai_tls_converge.yml"
            ).read_text()
        )
    )
)
cai_tls_by_name = {task.get("name"): task for task in cai_tls_tasks}
hostname_validation = cai_tls_by_name[
    "CAI TLS | Validate deterministic hostname and external input pairing"
]["ansible.builtin.assert"]
assert "ecs_cai_static_subdomain | length <= 15" in hostname_validation["that"]
assert "no longer than 15 characters" in hostname_validation["fail_msg"]
kubernetes_dependency_task = cai_tls_by_name[
    "CAI TLS | Ensure Kubernetes Python client is installed on ECS master"
]
assert kubernetes_dependency_task["ansible.builtin.pip"]["executable"] == "/usr/bin/pip3"
assert "oauthlib>=3.2.2,<5" in kubernetes_dependency_task["ansible.builtin.pip"]["name"]
assert "kubernetes" in kubernetes_dependency_task["ansible.builtin.pip"]["name"]
assert cai_tls_by_name[
    "CAI TLS | Verify Kubernetes Python client imports on ECS master"
]["failed_when"] is False
for task_name in (
    "CAI TLS | Read existing TLS secret",
    "CAI TLS | Read FreeIPA trust anchor",
    "CAI TLS | Stage existing secret for validation",
    "CAI TLS | Install FreeIPA-issued TLS secret",
    "CAI TLS | Install externally managed TLS secret when required",
    "CAI TLS | Read converged TLS secret",
    "CAI TLS | Stage converged secret for final validation",
):
    task = cai_tls_by_name[task_name]
    assert task["no_log"] is True
    assert task["failed_when"] is False

assert "no_log" not in cai_tls_by_name[
    "CAI TLS | Validate converged secret before createWorkspace"
]
freeipa_trust_read = cai_tls_by_name["CAI TLS | Read FreeIPA trust anchor"]
assert freeipa_trust_read["ansible.builtin.raw"] == "base64 --wrap=0 /etc/ipa/ca.crt"
assert freeipa_trust_read["connection"] == "ssh"
assert freeipa_trust_read["no_log"] is True

model_registry_tasks = list(
    flatten_tasks(
        yaml.safe_load(
            (
                root
                / "ansible-playbooks/common_tasks/ecs_data_service_model_registry.yml"
            ).read_text()
        )
    )
)
model_registry_ozone_include = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Retrieve Ozone S3 credentials from selected host"
)
assert model_registry_ozone_include["vars"]["ansible_python_interpreter"] == "/usr/bin/python3"
model_registry_create = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Create Model Registry"
)
model_registry_creator = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Resolve Model Registry creator CRN"
)
assert "ecs_model_registry_creator_crn" in str(model_registry_creator)
assert "ecs_ldap_admin_user_crn" in str(model_registry_creator)
model_registry_creator_assert = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Require human Model Registry creator CRN"
)
creator_assert_text = str(model_registry_creator_assert)
assert "':user:'" in creator_assert_text
assert "':machineuser:'" in creator_assert_text
creator_key_create = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Create temporary access key for Model Registry creator"
)
creator_key_create_text = str(creator_key_create)
assert "create-user-access-key" in creator_key_create_text
assert "--user" in creator_key_create_text
assert "--type" in creator_key_create_text
assert "V2" in creator_key_create_text
assert creator_key_create["environment"] == "{{ ecs_cdp_cli_environment }}"
assert creator_key_create["no_log"] is True
creator_key_parse = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Parse temporary Model Registry creator access key response"
)
assert "from_json" in str(creator_key_parse)
assert creator_key_parse["no_log"] is True
creator_key_resolve = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Resolve temporary Model Registry creator access key"
)
creator_key_resolve_text = str(creator_key_resolve)
assert "accessKeyId" in creator_key_resolve_text
assert "actorCrn" in creator_key_resolve_text
assert "privateKey" in creator_key_resolve_text
assert creator_key_resolve["no_log"] is True
creator_credentials = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Write temporary Model Registry creator credentials"
)
assert creator_credentials["no_log"] is True
creator_environment = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Resolve Model Registry creator CLI environment"
)
creator_environment_text = str(creator_environment)
assert "CDP_SHARED_CREDENTIALS_FILE" in creator_environment_text
assert "CDP_CREDENTIALS_PATH" in creator_environment_text
assert model_registry_create["no_log"] is True
assert model_registry_create["failed_when"] is False
assert model_registry_create["environment"] == "{{ ecs_mr_creator_cli_environment }}"
model_registry_create_text = str(model_registry_create)
for expected_flag in (
    "--namespace",
    "--creator-crn",
    "--s-3-access-key",
    "--s-3-secret-key",
    "--s-3-bucket",
    "--s-3-endpoint",
):
    assert expected_flag in model_registry_create_text
for obsolete_flag in (
    "--model-registry-service-name",
    "--model-registry-subdomain",
    "--s3-access-key",
    "--s3-secret-key",
    "--s3-bucket",
    "--s3-endpoint",
):
    assert obsolete_flag not in model_registry_create_text
creator_key_delete = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Delete temporary Model Registry creator access key"
)
assert "delete-access-key" in str(creator_key_delete)
assert "--access-key-id" in str(creator_key_delete)
assert creator_key_delete["environment"] == "{{ ecs_cdp_cli_environment }}"
assert creator_key_delete["no_log"] is True
creator_credentials_remove = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Remove temporary Model Registry creator credentials"
)
assert creator_credentials_remove["ansible.builtin.file"]["state"] == "absent"
human_create_block = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Create Model Registry as human creator"
)
assert human_create_block["always"]
always_names = [task.get("name") for task in human_create_block["always"]]
assert "Delete temporary Model Registry creator access key" in always_names
assert "Remove temporary Model Registry creator credentials" in always_names
model_registry_create_assert = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Require successful Model Registry creation"
)
assert "--s-?3-" in model_registry_create_assert["ansible.builtin.assert"]["fail_msg"]
sample_cli_error = (
    "Unknown options: --s-3-access-key, access-value, "
    "--s-3-secret-key, secret-value, --s-3-bucket, bucket"
)
redacted_cli_error = re.sub(
    r"(?i)(--s-?3-(?:access|secret)-key(?:\s+|,\s*))([^,\s]+)",
    r"\1<redacted>",
    sample_cli_error,
)
assert "access-value" not in redacted_cli_error
assert "secret-value" not in redacted_cli_error
assert redacted_cli_error.count("<redacted>") == 2

print("Data Services selection and CAI kubeconfig checks passed")
PY
