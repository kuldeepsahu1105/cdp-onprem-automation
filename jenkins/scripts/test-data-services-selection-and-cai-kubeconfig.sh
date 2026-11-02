#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import re
import sys
import yaml

root = Path(sys.argv[1])
playbook = root / "ansible-playbooks/roles/ecs/tasks/setup_data_services.yml"
playbook_text = playbook.read_text()

for service in ("cdw", "cde", "cai"):
    marker = f"- name: Provision {service.upper() if service != 'cai' else 'CAI'}"
    if service == "cdw":
        marker = "- name: Provision CDW"
    elif service == "cde":
        marker = "- name: Provision CDE"
    assert marker in playbook_text

assert "ansible.builtin.include_tasks: ecs_data_service_cdw_preflight.yml" in playbook_text
assert "Collect CDW diagnostics after uncaught failure" in playbook_text
assert "not (ecs_cdw_diagnostics_collected | default(false) | bool)" in playbook_text
assert "ansible.builtin.include_tasks: ecs_data_service_cde_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: ecs_data_service_cai_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: ecs_data_service_model_registry.yml" in playbook_text
assert "when: \"'model_registry' in (ecs_data_services_install_names | default([]))\"" in playbook_text

cai_files = list(
    (root / "ansible-playbooks/roles/ecs/tasks").glob("ecs_data_service_cai*.yml")
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
assert len(group_vars["ecs_cai_static_subdomain"]) <= 15
assert group_vars["ecs_cdp_environment_adopt_single_existing"] is False
assert group_vars["ecs_cdw_ensure_freeipa_principal_objects"] is True

cdw_preflight = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_preflight.yml"
).read_text()
cdw_diagnostics = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_diagnostics.yml"
).read_text()
cdw_force_reset = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_force_reset.yml"
).read_text()
cdw_setup = (
    root
    / "ansible-playbooks/roles/ecs/tasks/setup_data_services.yml"
).read_text()
for forbidden in (
    "ipa-getkeytab",
    "state: disabled",
    "Remove legacy automation-owned principals",
    "ecs_cdw_legacy_principal_cleanup_marker",
):
    assert forbidden not in cdw_preflight
assert "CDW | Ensure FreeIPA host principal object" in cdw_preflight
assert "CDW | Inspect FreeIPA Hive service principal" in cdw_preflight
assert "freeipa.ansible_freeipa.ipahost" in cdw_preflight
assert "CDW | Reject an existing keyless FreeIPA Hive principal" in cdw_preflight
assert "/cm/commands/generateCredentialsAdhoc" in cdw_preflight
assert "ecs_cdw_principals_to_generate" in cdw_preflight
assert "pre-created keyless service causes CM" in cdw_preflight
assert "CDW | Wait for CM-owned ad-hoc credentials" in cdw_preflight
assert "CDW | Require CM-generated FreeIPA keys" in cdw_preflight
assert "has_keytab: TRUE" in cdw_preflight
assert "deleteCredentials?deleteCredentialsMode=unused" in cdw_preflight
assert "CDW | Confirm stale CM credential recovery" in cdw_preflight
assert (
    "ecs_cdw_repair_stale_cm_credentials_confirm | default('')"
    in cdw_preflight
)
assert "== ecs_cdp_environment_name" in cdw_preflight
assert "ipa-getkeytab" not in cdw_preflight
assert "allow_create_keytab" not in cdw_preflight
assert "allow_retrieve_keytab" not in cdw_preflight
assert "freeipa.ansible_freeipa.ipaservice" not in cdw_preflight
assert "CDW | Require verified Base and CM Kerberos prerequisites" in cdw_preflight
assert "/cm/kerberosInfo" in cdw_preflight
assert "hadoop_security_authentication" in cdw_preflight
assert "ecs_cdw_preflight_cm_kerberized | bool" in cdw_preflight
assert "ecs_cdw_preflight_cm_realm == cluster_realm" in cdw_preflight
assert "ecs_cdw_preflight_cm_kdc_host == kdc_host" in cdw_preflight
assert "ecs_cdw_preflight_hdfs_authentication == 'kerberos'" in cdw_preflight
assert "ecs_cdw_force_reset_confirm == ecs_cdw_force_reset_cluster_id" in cdw_force_reset
assert "'delete-cluster'" in cdw_force_reset
assert "'--cluster-id'" in cdw_force_reset
assert "'--force'" in cdw_force_reset
assert "'describe-cluster'" in cdw_force_reset
assert "CDW recovery | Inspect confirmed cluster before deletion" in cdw_force_reset
assert "CDW recovery | Skip stale reset request for healthy or progressing cluster" in cdw_force_reset
assert "is search('(?i)^(error|failed)$')" in cdw_force_reset
assert "Clear ecs_cdw_force_reset_cluster_id" in cdw_force_reset
assert "not (ecs_cdw_force_reset_eligible | bool)" in cdw_force_reset
assert cdw_force_reset.count("when: ecs_cdw_force_reset_eligible | bool") == 2
assert "Status Code:\\\\s*404.*Error Code:\\\\s*NOT_FOUND" in cdw_force_reset
assert "until: ecs_cdw_force_reset_describe.rc != 0" in cdw_force_reset
assert "CDW diagnostics | Describe control-plane environment" in cdw_diagnostics
assert "/cm/kerberosInfo" in cdw_diagnostics
assert "hadoop_security_authentication" in cdw_diagnostics
assert "ipa host-show" not in cdw_diagnostics
assert "\n      - host-show\n" in cdw_diagnostics
assert "\n      - service-show\n" in cdw_diagnostics
assert "Likely failing boundary=" in cdw_diagnostics
assert "DWX-to-CM/KDC account-manager principal creation" in cdw_diagnostics
assert "ecs_cdw_diagnostics_collected: true" in cdw_diagnostics
assert "state: present" not in cdw_diagnostics
assert "ipa-getkeytab" not in cdw_diagnostics
assert "ecs_data_service_cdw_reconcile_workload_ccache.yml" not in cdw_setup

cdw_followup = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_followup.yml"
).read_text()
assert "ecs_cdw_trino_vw_name" in cdw_followup
assert "type: trino" in cdw_followup
assert "'create-vw'" in cdw_followup
assert "'--resource-pool'" in cdw_followup
assert "ecs_cdw_vw_resource_pool" in cdw_followup
assert "'--t-shirt-size'" in cdw_followup
assert "ecs_cdw_vw_tshirt_size" in cdw_followup
assert "'--impala-options'" in cdw_followup
assert "'--impala-ha-settings'" in cdw_followup
assert "'--autoscaling'" in cdw_followup
assert "'--additional-quota'" in cdw_followup
assert "'--impala-query-log'" in cdw_followup
assert "'--no-impala-query-log'" in cdw_followup
assert "Validate configured Impala Virtual Warehouse settings" in cdw_followup
assert "item.virtual_warehouses | default([]) | length == 0" in cdw_followup
assert "ecs_data_service_cdw_reconcile_vw_ccaches.yml" not in cdw_followup
assert "'describe-dbc-config'" in cdw_followup
assert "'update-dbc'" in cdw_followup
assert "'describe-vw-config'" in cdw_followup
assert "'update-vw'" in cdw_followup
assert "ecs_cdw_dbc_file_ccache_config | to_json" in cdw_followup
assert cdw_followup.count("ecs_cdw_vw_file_ccache_config | to_json") == 2
assert cdw_followup.count(".get(\"KRB5CCNAME\", \"\")") == 2
assert "failed_when: ecs_cdw_dbc_ccache_check.rc not in [0, 3]" in cdw_followup
assert "failed_when: ecs_cdw_vw_ccache_checks.rc not in [0, 3]" in cdw_followup
assert (
    cdw_followup.index("Persist database catalog FILE credential cache through CDW API")
    < cdw_followup.index("\n    - name: Wait for default database catalog\n")
)
assert (
    cdw_followup.index("Persist Virtual Warehouse FILE credential caches through CDW API")
    < cdw_followup.index("CDW Virtual Warehouses to finish provisioning")
)
assert "CDW Virtual Warehouses to finish provisioning" in cdw_followup
assert group_vars["ecs_cdw_vw_tshirt_size"] == "xsmall"
assert group_vars["ecs_cdw_vw_resource_pool"] == "root.{{ ecs_cdp_environment_name }}.cdw"
assert group_vars["ecs_cdw_impala_ha_settings"]["highAvailabilityMode"] == "DISABLED"
assert group_vars["ecs_cdw_impala_ha_settings"]["enableShutdownOfCoordinator"] is False
assert group_vars["ecs_cdw_impala_autoscaling"]["minClusters"] == 1
assert group_vars["ecs_cdw_impala_autoscaling"]["maxClusters"] == 5
assert group_vars["ecs_cdw_impala_autoscaling"]["autoSuspendTimeoutSeconds"] == 300
assert group_vars["ecs_cdw_impala_autoscaling"]["impalaScaleUpDelaySeconds"] == 20
assert group_vars["ecs_cdw_impala_autoscaling"]["impalaScaleDownDelaySeconds"] == 300
assert group_vars["ecs_cdw_impala_additional_quota"] == {"cpu": 0.0, "memory": 0}
assert group_vars["ecs_cdw_impala_query_log"] is True
assert group_vars["ecs_cdw_vw_krb5ccname"] == "FILE:/tmp/krb5cc_cdw"
assert (
    group_vars["ecs_cdw_dbc_file_ccache_config"]["commonConfigs"]["configBlocks"][0]
    ["content"]["keyValues"]["KRB5CCNAME"]
    == "{{ ecs_cdw_workload_krb5ccname }}"
)
assert (
    group_vars["ecs_cdw_vw_file_ccache_config"]["commonConfigs"]["configBlocks"][0]
    ["content"]["keyValues"]["KRB5CCNAME"]
    == "{{ ecs_cdw_vw_krb5ccname }}"
)

ozone_credentials = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_model_registry_ozone_credentials.yml"
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
                / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_tls_converge.yml"
            ).read_text()
        )
    )
)
cai_tls_by_name = {task.get("name"): task for task in cai_tls_tasks}
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
                / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_model_registry.yml"
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
assert model_registry_create["no_log"] is True
assert model_registry_create["failed_when"] is False
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
model_registry_creator_assert = next(
    task
    for task in model_registry_tasks
    if task.get("name") == "Require a human Model Registry creator"
)
creator_assert_text = str(model_registry_creator_assert)
assert ":user:" in creator_assert_text
assert ":machineUser:" in creator_assert_text
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
