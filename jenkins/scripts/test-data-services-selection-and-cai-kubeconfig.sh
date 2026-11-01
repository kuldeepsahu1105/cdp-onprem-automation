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
portal_facts_import = (
    "ansible.builtin.import_tasks: common_tasks/build_deployment_portal_facts.yml"
)
caddy_sync_import = (
    "ansible.builtin.import_tasks: common_tasks/ecs_data_services_sync_caddy.yml"
)
assert portal_facts_import in playbook_text
assert caddy_sync_import in playbook_text
assert playbook_text.index(portal_facts_import) < playbook_text.index(caddy_sync_import)
portal_refresh_task = next(
    task
    for task in yaml.safe_load(playbook.read_text())[1]["tasks"]
    if task.get("name")
    == "Refresh optional deployment portal routes for ECS data services"
)
assert portal_refresh_task["when"] == [
    "ecs_caddy_data_service_routes | default([]) | length > 0",
    "deployment_portal_caddy_effective | default(false) | bool",
]
portal_host_task = next(
    task
    for task in portal_refresh_task["block"]
    if task.get("name") == "Resolve deployment portal target host group"
)
assert "when" not in portal_host_task
portal_refresh_names = [task.get("name") for task in portal_refresh_task["block"]]
assert portal_refresh_names.index(
    "Build deployment portal facts for ECS ingress sync"
) < portal_refresh_names.index(
    "Sync ECS data service routes on deployment portal Caddy"
)
portal_facts_task = next(
    task
    for task in portal_refresh_task["block"]
    if task.get("name") == "Build deployment portal facts for ECS ingress sync"
)
assert portal_facts_task["when"] == (
    "ecs_ds_portal_compose.stat.exists | default(false) | bool"
)
assert portal_refresh_task["rescue"]
assert (
    portal_refresh_task["rescue"][0]["name"]
    == "Report optional deployment portal route refresh failure"
)
playbook_tasks = yaml.safe_load(playbook.read_text())[1]["tasks"]
catalog_dir_task = next(
    task
    for task in playbook_tasks
    if task.get("name") == "Create ECS data-service catalog cache directory"
)
catalog_write_task = next(
    task
    for task in playbook_tasks
    if task.get("name")
    == "Persist ECS data-service catalog for portal refresh and email URLs"
)
assert catalog_dir_task["become"] is True
assert catalog_dir_task["ansible.builtin.file"]["mode"] == "0755"
assert catalog_write_task["become"] is True
assert catalog_write_task["ansible.builtin.copy"]["mode"] == "0644"
caddy_sync = (
    root / "ansible-playbooks/common_tasks/ecs_data_services_sync_caddy.yml"
).read_text()
assert "src: deployment_portal_Caddyfile.j2" in caddy_sync
caddy_template = (
    root / "ansible-playbooks/templates/deployment_portal_Caddyfile.j2"
).read_text()
assert "caddy_vhost_urls_external" in caddy_template

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
assert group_vars["ecs_cde_service_name_attempts"] == 10
assert group_vars["ecs_cde_service_name_max_length"] == 40
assert group_vars["ecs_cde_virtual_cluster_name_attempts"] == 10
assert group_vars["ecs_cde_virtual_cluster_cpu_requests"] == "20"
assert group_vars["ecs_cde_virtual_cluster_memory_requests"] == "30Gi"
assert group_vars["ecs_cdw_dataviz_name_attempts"] == 10
assert group_vars["ecs_cdw_vw_name_attempts"] == 10
assert group_vars["ecs_cdw_dataviz_user_groups"] == []
assert group_vars["ecs_cdw_dataviz_admin_groups"] == []
assert group_vars["ecs_cai_static_subdomain"] == "cai"
assert group_vars["ecs_cai_workspace_name"] == "cai-wb-1"
assert group_vars["ecs_model_registry_creator_crn"] == ""
assert "playbook_dir" in group_vars["ecs_data_services_catalog_cache_path"]
assert (
    group_vars["ecs_data_services_catalog_legacy_cache_path"]
    == "{{ ecs_persistent_state_dir }}/ecs-data-services-catalog.yml"
)

portal_facts = yaml.safe_load(
    (root / "ansible-playbooks/common_tasks/build_deployment_portal_facts.yml").read_text()
)
catalog_stat = next(
    task
    for task in portal_facts
    if task.get("name") == "Check cached ECS data-service catalog"
)
assert catalog_stat["failed_when"] is False
legacy_catalog_stat = next(
    task
    for task in portal_facts
    if task.get("name") == "Check legacy cached ECS data-service catalog"
)
assert legacy_catalog_stat["failed_when"] is False
catalog_path_resolve = next(
    task
    for task in portal_facts
    if task.get("name") == "Resolve readable ECS data-service catalog cache"
)
assert "stat.exists" in str(catalog_path_resolve)
catalog_read = next(
    task
    for task in portal_facts
    if task.get("name") == "Read cached ECS data-service catalog with controller privileges"
)
assert "ansible.builtin.slurp" in catalog_read
assert catalog_read["become"] is True
catalog_load = next(
    task
    for task in portal_facts
    if task.get("name") == "Load cached ECS data-service catalog"
)
assert "lookup('file'" not in str(catalog_load)
catalog_normalize = next(
    task
    for task in portal_facts
    if task.get("name") == "Normalize cached ECS data-service catalog payload"
)
assert ".content" in str(catalog_normalize)
assert "default('', true)" in str(catalog_normalize)
catalog_missing_warning = next(
    task
    for task in portal_facts
    if task.get("name") == "Report optional unreadable ECS data-service catalog"
)
assert "Continuing with the in-memory/default catalog" in str(
    catalog_missing_warning
)
catalog_decode = next(
    task
    for task in portal_facts
    if task.get("name") == "Decode optional ECS data-service catalog"
)
assert catalog_decode["rescue"]
assert "b64decode" in str(catalog_decode)
assert "deployment_portal_ecs_ds_catalog_parsed | default({})" in str(catalog_load)
portal_link_task = next(
    task
    for task in portal_facts
    if task.get("name") == "Add ECS data service URLs to portal when configured"
)
assert "item.link" not in str(portal_link_task["ansible.builtin.set_fact"])
assert "deployment_portal_ecs_ds_links + [link]" in str(
    portal_link_task["ansible.builtin.set_fact"]
)
assert "virtual_cluster" in str(portal_link_task["vars"]["_url"])
assert "data_visualization" in str(portal_link_task["vars"]["_url"])
assert "_url | default('') | string | length > 0" in portal_link_task["when"]

cai_preflight = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_preflight.yml"
).read_text()
cai_start = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_start.yml"
).read_text()
cai_endpoint = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_endpoint.yml"
).read_text()
cai_wait = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_wait.yml"
).read_text()
cai_attempt = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_create_attempt.yml"
).read_text()
assert "ecs_cai_workspace_candidate_names" in cai_preflight
assert "ecs_cai_subdomain_candidate_names" in cai_preflight
assert "ecs_cai_workspace_name_effective" in cai_preflight
assert "ecs_cai_static_subdomain_effective" in cai_preflight
assert "Reuse healthy workspace owning configured base endpoint" in cai_preflight
assert "item.instanceUrl" in cai_preflight
assert "else []" in cai_preflight
assert "range(1, (ecs_cai_workspace_name_attempts | int) + 1)" in cai_preflight
assert "regex_search('([0-9]+)$')" in cai_preflight
assert "_ecs_cai_numeric_suffix | int" in cai_preflight
assert "selectattr('instanceName', 'equalto', item)" in cai_preflight
for cai_info_text in (cai_endpoint, cai_wait):
    assert (
        "selectattr('instanceName', 'equalto', ecs_cai_workspace_name_effective)"
        in cai_info_text
    )
for cai_info_tasks in (
    yaml.safe_load(cai_preflight),
    yaml.safe_load(cai_attempt),
    yaml.safe_load(cai_endpoint),
    yaml.safe_load(cai_wait),
):
    for task in cai_info_tasks:
        if "cloudera.cloud.ml_info" in task:
            assert "name" not in task["cloudera.cloud.ml_info"]
cai_start_tasks = yaml.safe_load(cai_start)
cai_attempt_include = next(
    task
    for task in cai_start_tasks
    if task.get("name") == "CAI | Try bounded workspace names until created or adopted"
)
assert "ecs_data_service_cai_create_attempt.yml" in str(cai_attempt_include)
assert cai_attempt_include["loop"] == "{{ ecs_cai_workspace_create_candidates }}"
exhausted_assert = next(
    task
    for task in cai_start_tasks
    if task.get("name") == "CAI | Require a created or reusable workspace"
)
assert "bounded name attempts" in exhausted_assert["ansible.builtin.assert"]["fail_msg"]
assert "does not delete" in exhausted_assert["ansible.builtin.assert"]["fail_msg"]
cai_attempt_tasks = yaml.safe_load(cai_attempt)
cai_create = next(
    task
    for task in cai_attempt_tasks
    if task.get("name") == "CAI attempt | Submit workspace creation for unused candidate"
)
assert cai_create["failed_when"] is False
reconcile_lookup = next(
    task
    for task in cai_attempt_tasks
    if task.get("name") == "CAI attempt | Refresh inventory after every submission"
)
assert "name" not in reconcile_lookup["cloudera.cloud.ml_info"]
assert "ecs_cai_workspace_reconcile_retries" in str(reconcile_lookup)
assert "ecs_cai_workspace_candidate" in str(reconcile_lookup["until"])
collision_record = next(
    task
    for task in cai_attempt_tasks
    if task.get("name") == "CAI attempt | Classify unresolved collision"
)
assert "endpoint_owner" in str(collision_record)
assert "ecs_cai_workspace_candidate" in str(collision_record)
assert "subdomain: \"{{ ecs_cai_static_subdomain_effective }}\"" in cai_attempt
assert "Adopt real submitted candidate regardless submission rc" in cai_attempt
assert "Adopt real reusable endpoint owner" in cai_attempt
assert "Reconcile TLS to adopted authoritative endpoint" in cai_attempt
assert "instanceUrl" in cai_attempt
assert "else ecs_cai_candidate_subdomain" in cai_attempt
assert "rc/output alone cannot prove absence" in cai_attempt
assert "endpoint .*used by workbench" in cai_attempt
assert "ecs_cai_tls_subdomain_validated" in cai_attempt
assert group_vars["ecs_cai_workspace_name_attempts"] == 10
assert group_vars["ecs_cai_workspace_name_max_length"] == 40
assert group_vars["ecs_cai_workspace_reconcile_retries"] == 6
assert "ecs_cai_workspace_name_effective" in (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_followup.yml"
).read_text()
assert "'effective_subdomain': ecs_cai_static_subdomain_effective" in (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_followup.yml"
).read_text()
assert "CAI | Report authoritative reusable workspace" in cai_preflight
assert "No rename or duplicate create is performed" in cai_preflight
cai_result_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai.yml"
).read_text()
assert "Existing and running (green)" in cai_result_text
assert "Created successfully (green)" in cai_result_text
assert "effective_name=" in cai_result_text
assert "Report CAI Workbench outcome" in cai_result_text
assert "Existing and running; reused without create or rename" in cai_result_text
for field in ("instanceName=", "observed_status=", "endpoint=", "environment="):
    assert field in cai_result_text
assert "create_failed" in cai_attempt.lower()
cai_followup_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cai_followup.yml"
).read_text()
assert "'effective_name': ecs_cai_workspace_name_effective" in cai_followup_text
assert "'status': (" in cai_followup_text
assert "ecs_model_registry_status" in playbook_text
assert "success_msg:" in playbook_text
assert "CAI Workbench:" in playbook_text
assert "Model Registry:" in playbook_text
assert "CDE Service:" in playbook_text
assert "Virtual Cluster:" in playbook_text
assert "DataViz status=" in playbook_text
assert "Existing (healthy)" in (
    root / "ansible-playbooks/common_tasks/ecs_data_service_model_registry.yml"
).read_text()
model_registry_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_model_registry.yml"
).read_text()
assert "Report existing healthy Model Registry" in model_registry_text
assert "no create or credential mutation performed" in model_registry_text
for field in ("serviceName=", "namespace=", "observed_status=", "environment=", "endpoint=", "crn="):
    assert field in model_registry_text
assert "success_msg:" in model_registry_text
assert "installed|ready|running" in (
    root / "ansible-playbooks/common_tasks/ecs_data_service_model_registry.yml"
).read_text()
assert "Created successfully" in (
    root / "ansible-playbooks/common_tasks/ecs_data_service_model_registry.yml"
).read_text()

cde_preflight_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cde_preflight.yml"
).read_text()
assert "--no-remove-deleted" in cde_preflight_text
assert "ecs_cde_service_candidate_names" in cde_preflight_text
assert "ecs_cde_service_name_effective" in cde_preflight_text
assert "clustercreationcompleted" in cde_preflight_text.lower()
cde_start_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cde_start.yml"
).read_text()
assert 'name: "{{ ecs_cde_service_name_effective }}"' in cde_start_text
assert "Wait for adopted service without mutating its sizing" in cde_start_text
assert "not (ecs_cde_service_existing | default(false) | bool)" in cde_start_text
cde_vc_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cde_virtual_cluster.yml"
).read_text()
assert "de', 'list-vcs'" in cde_vc_text
assert "selectattr('vcName', 'equalto', candidate)" in cde_vc_text
assert "ecs_cde_vc_candidate_names" in cde_vc_text
assert "ecs_cde_virtual_cluster_name_effective" in cde_vc_text
assert "AppInstalled" in cde_vc_text
assert "appinstallationfailed" in cde_vc_text.lower()
assert "wait: false" in cde_vc_text
assert "Automation does not delete the failed resource" in cde_vc_text
assert "ecs_data_service_cde_virtual_cluster.yml" in (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cde.yml"
).read_text()

dataviz_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cdw_dataviz.yml"
).read_text()
assert "list-data-visualizations" in dataviz_text
assert "create-data-visualization" in dataviz_text
assert "ecs_cdw_dataviz_candidate_names" in dataviz_text
assert "Failed, Error, and Deleting" in dataviz_text
assert "'userGroups': ecs_cdw_dataviz_user_groups" in dataviz_text
assert "'adminGroups': ecs_cdw_dataviz_admin_groups" in dataviz_text
cdw_followup_text = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cdw_followup.yml"
).read_text()
assert "ecs_data_service_cdw_dataviz.yml" in cdw_followup_text
assert "ecs_cdw_dataviz_succeeded: false" in cdw_followup_text
assert "list-vws" in cdw_followup_text
assert "ecs_cdw_hive_vw_name_effective" in cdw_followup_text
assert "ecs_cdw_impala_vw_name_effective" in cdw_followup_text

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
assert "ecs_cai_static_subdomain_effective | length <= 15" in hostname_validation["that"]
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
