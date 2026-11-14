#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import yaml

root = Path(sys.argv[1])
credentials_parser = (
    root / "ansible-playbooks/files/parse_ecs_api_credentials_cache.py"
)
with tempfile.TemporaryDirectory() as temp_dir:
    cache_path = Path(temp_dir) / "credentials.yml"
    cache_path.write_text(
        "access_key_id: automation-key\n"
        "private_key: private-key\n"
        "bootstrap_access_key_id: installer-key\n"
    )
    parsed_cache = json.loads(
        subprocess.check_output(
            [sys.executable, str(credentials_parser), str(cache_path)],
            text=True,
        )
    )
assert parsed_cache == {
    "access_key_id": "automation-key",
    "private_key": "private-key",
    "bootstrap_access_key_id": "installer-key",
}

credentials_load_text = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_load_api_credentials.yml"
).read_text()
assert "Read current installer IAM credentials for cache identity" in credentials_load_text
assert "Report ECS API credential cache from another cluster" in credentials_load_text
assert (
    "bootstrap_access_key_id\n"
    "        == ecs_api_credentials_expected_bootstrap_access_key_id"
    in credentials_load_text
)
credentials_provision_text = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_provision_iam_machine_access_key.yml"
).read_text()
assert (
    "bootstrap_access_key_id: "
    "{{ ecs_iam_bootstrap_access_key_id_effective | to_json }}"
    in credentials_provision_text
)
assert "Describe requested ECS environment before creation" in credentials_provision_text
assert "'describe-environment'" in credentials_provision_text
assert "Parse requested ECS environment response" in credentials_provision_text
assert "Select directly described ECS environment response" in credentials_provision_text
assert "Normalize directly described ECS environment" in credentials_provision_text
assert "ecs_requested_environment_describe_payload.environment" in credentials_provision_text
assert "ecs_requested_environment_candidate.name" in credentials_provision_text
assert "ecs_requested_environment_direct" in credentials_provision_text
assert "Report matching existing ECS environment" in credentials_provision_text
assert "Existing ECS environment found; creation will be skipped." in credentials_provision_text
assert "ecs_requested_environment_matches[0].environmentName" in credentials_provision_text
assert "ecs_requested_environment_matches[0].crn" in credentials_provision_text
assert "ecs_requested_environment_matches[0].clusterNames" in credentials_provision_text
assert "Report ECS environment lookup before creation" in credentials_provision_text
assert "response keys=" in credentials_provision_text
assert "Sanitize requested ECS environment lookup error" in credentials_provision_text
assert "Sanitize ECS environment list error" in credentials_provision_text
assert "Sanitize ECS environment creation error" in credentials_provision_text
assert "Fail with sanitized ECS environment creation error" in credentials_provision_text
assert "create-private-environment failed for" in credentials_provision_text
assert "failed_when: false" in credentials_provision_text
assert "ignore_errors: true" in credentials_provision_text
assert "default(ecs_create_environment.msg, true)" in credentials_provision_text
assert "| default(ecs_automation_environment.stdout | from_json, true)" in credentials_provision_text
assert credentials_provision_text.index(
    "Describe requested ECS environment before creation"
) < credentials_provision_text.index("Create missing ECS private-cloud environment")

playbook = root / "ansible-playbooks/roles/ecs/tasks/setup_data_services.yml"
playbook_text = playbook.read_text()
diagnostics_text = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_diagnostics.yml"
).read_text()

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
assert "ansible_failed_result.msg" in playbook_text
assert "ansible_failed_task.name" in playbook_text
assert "details: \"{{ ansible_failed_result }}\"" in playbook_text
assert "One or more selected Data Services failed:" in playbook_text
assert "- CDW: task=" in playbook_text
assert "CDW details=" not in playbook_text
assert "| truncate(500, true, '...')" in playbook_text
assert "Collect failed CDW persistent volume claims" in diagnostics_text
assert "Collect pending CDW pod names" not in diagnostics_text
assert "Describe pending CDW pods" not in diagnostics_text
assert "Collect ECS node scheduling capacity" not in diagnostics_text
assert "ansible.builtin.include_tasks: ecs_data_service_cde_preflight.yml" in playbook_text
assert playbook_text.index("Provision CDE before capacity-intensive CDW warehouses") < (
    playbook_text.index("Provision CDW without blocking subsequent services")
)
assert "ansible.builtin.include_tasks: ecs_data_service_cai_preflight.yml" in playbook_text
assert "ansible.builtin.include_tasks: ecs_data_service_model_registry.yml" in playbook_text
assert "ecs_reconcile_coredns.yml" in playbook_text
assert "ecs_data_services_verify_dns.yml" in playbook_text
assert playbook_text.index(
    "Resolve CM API endpoint for ECS Data Services"
) < playbook_text.index(
    "Ensure Base SDX Data Context before Data Services provisioning"
) < playbook_text.index(
    "Reconcile CoreDNS before Data Services provisioning"
) < playbook_text.index(
    "Verify Data Services DNS through Kubernetes pods"
) < playbook_text.index(
    "Load existing ECS automation API credentials"
)
sdx_gate = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_ensure_base_data_context.yml"
).read_text()
assert "Data Services SDX | Ensure base cluster Data Context" in sdx_gate
assert "ecs_cm_api_base_url" in sdx_gate
assert "127.0.0.1" not in sdx_gate
assert "/clusters/" not in sdx_gate
assert "common_tasks/ensure_base_cluster_data_context.yml" in sdx_gate
assert "cm_cluster_module_delegate_to: \"{{ cm_manager_inventory_host }}\"" in sdx_gate
assert "ecs_data_services_base_data_context_enabled | default(true) | bool" in playbook_text

cm_endpoint = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_resolve_cm_api_endpoint.yml"
).read_text()
for candidate in (
    "cm_host_private",
    "private_ip",
    "cm_host_fqdn",
    "ansible_host",
    "127.0.0.1",
):
    assert candidate in cm_endpoint
assert "ECS CM API | Probe HTTPS endpoints from manager" in cm_endpoint
assert "ECS CM API | Probe HTTP endpoints when HTTPS is unavailable" in cm_endpoint

for relative_path in (
    "ansible-playbooks/roles/ecs/tasks/ecs_ensure_base_data_context.yml",
    "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_preflight.yml",
    "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_diagnostics.yml",
):
    text = (root / relative_path).read_text()
    assert "://127.0.0.1:" not in text, relative_path

base_sdx_helper = (
    root
    / "ansible-playbooks/roles/cdh_base_cluster/tasks/ensure_base_cluster_data_context.yml"
).read_text()
assert "Base data context | Create configured context for fresh cluster" in base_sdx_helper
assert "Base data context | Require complete fresh-install prerequisite" in base_sdx_helper
assert 'cm_cluster_module_api_url }}/dataContexts' in base_sdx_helper
assert base_sdx_helper.count("connection: ssh") == 3
base_setup = (
    root
    / "ansible-playbooks/roles/cdh_base_cluster/tasks/setup_base_cluster.yml"
).read_text()
assert base_setup.index(
    "Ensure base cluster Data Context for fresh Data Services installation"
) < base_setup.index("Record completed base cluster initialization")
base_sdx_compat = (
    root / "ansible-playbooks/common_tasks/ensure_base_cluster_data_context.yml"
).read_text()
assert "name: cdh_base_cluster" in base_sdx_compat
assert "tasks_from: ensure_base_cluster_data_context" in base_sdx_compat
ecs_sdx_compat = (
    root / "ansible-playbooks/common_tasks/ecs_ensure_base_data_context.yml"
).read_text()
assert "name: ecs" in ecs_sdx_compat
assert "tasks_from: ecs_ensure_base_data_context" in ecs_sdx_compat
assert "when: \"'model_registry' in (ecs_data_services_install_names | default([]))\"" in playbook_text
selection_text = (
    root
    / "ansible-playbooks/roles/ecs/tasks/resolve_ecs_data_services_install.yml"
).read_text()
assert "Report ECS data service enablement" in selection_text
assert "'ENABLED' if 'cdw' in ecs_data_services_install_names" in selection_text
assert "'ENABLED' if 'cde' in ecs_data_services_install_names" in selection_text
assert "'ENABLED' if 'cai' in ecs_data_services_install_names" in selection_text
assert "'model_registry' in ecs_data_services_install_names" in selection_text

compat_playbook_text = (
    root / "ansible-playbooks/34_setup_ecs_data_services.yml"
).read_text()
assert "name: ecs" in compat_playbook_text
assert "tasks_from: setup_data_services" in compat_playbook_text
assert "ecs_reconcile_coredns.yml" not in compat_playbook_text
assert "ecs_data_services_verify_dns.yml" not in compat_playbook_text

role_data_services = yaml.safe_load(
    (
        root / "ansible-playbooks/roles/ecs/tasks/setup_data_services.yml"
    ).read_text()
)
profile_cleanup = next(
    task
    for task in role_data_services
    if task.get("name") == "Remove temporary Data Services profile from ECS master"
)
assert profile_cleanup["become"] is True
assert profile_cleanup["ansible.builtin.file"]["state"] == "absent"
portal_gate = next(
    task
    for task in role_data_services
    if task.get("name") == "Resolve deployment portal Caddy gate for ECS ingress sync"
)
portal_host = next(
    task
    for task in role_data_services
    if task.get("name") == "Resolve deployment portal target host group"
)
portal_facts = next(
    task
    for task in role_data_services
    if task.get("name") == "Build deployment portal facts for ECS ingress sync"
)
portal_sync = next(
    task
    for task in role_data_services
    if task.get("name") == "Sync ECS data service routes on deployment portal Caddy"
)
portal_route_gate = "ecs_data_services_sync_portal_routes | default(true) | bool"
assert portal_gate["when"] == portal_route_gate
assert portal_host["when"] == portal_route_gate
assert portal_route_gate in portal_facts["when"]
assert "deployment_portal_caddy_effective | default(false) | bool" in portal_facts["when"]
assert role_data_services.index(portal_facts) < role_data_services.index(portal_sync)
assert portal_route_gate in portal_sync["when"]

cai_files = list(
    (root / "ansible-playbooks/roles/ecs/tasks").glob("ecs_data_service_cai*.yml")
)
combined = "\n".join(path.read_text() for path in cai_files)
assert "ecs_kubeconfig_path" not in combined
assert "ecs_coredns_kubeconfig_path" in combined

group_vars = yaml.safe_load(
    (root / "ansible-playbooks/group_vars/all.yml").read_text()
)
assert group_vars["ecs_cde_virtual_cluster_name_max_length"] == 30
assert group_vars["ecs_cde_virtual_cluster_prefix_max_length"] == 8
cde_vc_text = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cde_virtual_cluster.yml"
).read_text()
assert "CDE VC | Validate API-compatible candidate names" in cde_vc_text
assert "<= ecs_cde_virtual_cluster_name_max_length | int" in cde_vc_text
assert "deployment_prefix[:prefix_length]" in cde_vc_text
assert "stable_tail" in cde_vc_text
assert "start and end with an" in cde_vc_text
assert "CDE VC | Require successful Virtual Cluster creation" not in cde_vc_text
assert "failed_when: false" not in cde_vc_text
configured_vc_name = "autodeploytest-ecs-cluster-de-vc"
deployment_prefix = "autodeploytest"
stable_tail = configured_vc_name[len(deployment_prefix) :]
vc_candidates = []
for attempt in range(1, group_vars["ecs_cde_virtual_cluster_name_attempts"] + 1):
    suffix = "" if attempt == 1 else f"-{attempt - 1}"
    stem_length = 30 - len(suffix)
    if len(configured_vc_name) <= stem_length:
        stem = configured_vc_name
    else:
        prefix_length = min(
            group_vars["ecs_cde_virtual_cluster_prefix_max_length"],
            stem_length - len(stable_tail),
        )
        stem = deployment_prefix[:prefix_length].rstrip("-") + stable_tail
    vc_candidates.append(stem + suffix)
assert vc_candidates[0] == "autodepl-ecs-cluster-de-vc"
assert vc_candidates[1] == "autodepl-ecs-cluster-de-vc-1"
assert all(len(candidate) <= 30 for candidate in vc_candidates)
assert all(re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?", candidate) for candidate in vc_candidates)
short_vc_name = "short-de-vc"
short_vc_candidates = []
for attempt in range(1, 3):
    suffix = "" if attempt == 1 else f"-{attempt - 1}"
    stem_length = 30 - len(suffix)
    stem = short_vc_name if len(short_vc_name) <= stem_length else short_vc_name[:stem_length].rstrip("-")
    short_vc_candidates.append(stem + suffix)
assert short_vc_candidates == ["short-de-vc", "short-de-vc-1"]
for service in ("HDFS", "HIVE", "ATLAS", "RANGER"):
    assert service in group_vars["base_cluster_data_context_services"]
assert group_vars["base_cluster_data_context_enabled"] is True
assert group_vars["ecs_data_services_base_data_context_enabled"] is True
assert group_vars["base_cluster_data_context_name"] == "SDX"
assert group_vars["base_cluster_ranger_usersync_provider_allowed"] == [
    "auto",
    "freeipa",
    "ad",
    "external",
    "none",
]
assert group_vars["base_cluster_ranger_usersync_delta_sync"] is True
assert group_vars["base_cluster_ranger_usersync_user_search_scope"] == "sub"
assert group_vars["base_cluster_ranger_usersync_group_search_scope"] == "sub"
assert group_vars["base_cluster_ranger_usersync_referral"] == "follow"
assert group_vars["base_cluster_ranger_usersync_unix_backend"] == "nss"
assert group_vars["ecs_coredns_kubeconfig_path"] == "/etc/rancher/rke2/rke2.yaml"
assert group_vars["ecs_cde_cpu_requests"] == "300"
assert group_vars["ecs_cde_memory_requests"] == "1000Gi"
assert group_vars["ecs_cai_static_subdomain"] == "cai"
assert len(group_vars["ecs_cai_static_subdomain"]) <= 15
assert group_vars["ecs_cdp_environment_adopt_single_existing"] is False
assert group_vars["ecs_cdw_ensure_freeipa_principal_objects"] is True
assert group_vars["ecs_ldap_enabled"] is True
assert group_vars["ecs_ldap_admin_user_enabled"] is True
assert group_vars["ecs_ldap_provider"] == "auto"

ldap_phase = (
    root
    / "ansible-playbooks/roles/ecs/tasks/resolve_ecs_control_plane_iam_phase.yml"
).read_text()
ldap_control = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_control_plane_ldap_and_admin.yml"
).read_text()
ldap_provider = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_data_services_ldap.yml"
).read_text()
ldap_credential_refresh = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_validate_or_refresh_api_credentials.yml"
).read_text()
ldap_freeipa_user = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_ldap_freeipa_admin_user.yml"
).read_text()
assert "ecs_ldap_provider_effective != 'none'" in ldap_phase
assert "ecs_ldap_resolve_environment_flags | default(true) | bool" in ldap_phase
assert "ecs_ldap_provider_effective == 'freeipa'" in ldap_control
assert "freeipa.ansible_freeipa.ipauser" in ldap_freeipa_user
assert "LDAP | Set provider argv for external LDAP" in ldap_provider
assert "base_cluster_ranger_usersync_bind_dn" in ldap_provider
assert "base_cluster_ranger_usersync_bind_password" in ldap_provider
assert "+ ['iam', 'list-users']" in ldap_credential_refresh
assert "get-access-key" not in ldap_credential_refresh
assert "No access key found".lower() in ldap_credential_refresh.lower()
assert "ecs_provision_iam_machine_access_key.yml" in ldap_credential_refresh
assert "ecs_control_plane_remote_runtime.yml" in ldap_credential_refresh
remote_runtime = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_control_plane_remote_runtime.yml"
).read_text()
assert "ecs_remote_cdp_missing_command_options" in remote_runtime
assert 'loop: "{{ ecs_remote_cdp_command_help.results }}"' not in remote_runtime
assert "quiet: true" in remote_runtime
assert "ecs_validate_or_refresh_api_credentials.yml" in ldap_control

base_cluster_role = (
    root / "ansible-playbooks/roles/cdh_base_cluster/tasks/setup_base_cluster.yml"
).read_text()
assert "Configure Ranger Admin LDAP authentication" in base_cluster_role
assert "Configure Ranger UserSync LDAP provider" in base_cluster_role
assert "Restore Ranger Admin local authentication when directory integration is disabled" in (
    base_cluster_role
)
assert "Disable existing Ranger UserSync when directory integration is disabled" in (
    base_cluster_role
)
assert base_cluster_role.index("Configure Ranger Admin LDAP authentication") < (
    base_cluster_role.index("Configure Ranger UserSync LDAP provider")
)
base_cluster_spec = (
    root
    / "ansible-playbooks/roles/cdh_base_cluster/templates/base_cluster_cluster_spec.j2"
).read_text()
assert "base_cluster_ranger_admin_ldap_config.items()" in base_cluster_spec
assert "base_cluster_ranger_usersync_role_config.items()" in base_cluster_spec
assert "ranger.usersync.enabled" in str(
    group_vars["base_cluster_ranger_usersync_role_config"]
)
assert "ranger.usersync.ldap.starttls" in str(
    group_vars["base_cluster_ranger_usersync_role_config"]
)

cdw_preflight = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_preflight.yml"
).read_text()
cm_command_wait = (
    root / "ansible-playbooks/roles/cm_security/tasks/wait_cm_api_command.yml"
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
assert "CDW | Report submitted CM ad-hoc credential command" in cdw_preflight
assert "CDW | Report existing Data Warehouse clusters" in cdw_preflight
assert "CDW | Report absent Data Warehouse cluster" in cdw_preflight
assert "action=REUSE" in cdw_preflight
assert "action=CREATE" in cdw_preflight
assert "This internal API command may not appear in the Cloudera Manager UI" in cdw_preflight
assert "cm_api_command_label: CM internal ad-hoc credential command" in cdw_preflight
assert "CDW | Wait for CM-owned ad-hoc credentials" in cdw_preflight
assert "ecs_cdw_credential_command_poll_retries" in cdw_preflight
assert "ecs_cdw_credential_command_poll_delay" in cdw_preflight
assert "ecs_cdw_credential_command_request_timeout" in cdw_preflight
assert cdw_preflight.count("cm_api_command_connection: ssh") == 2
assert "status_code: [200, 404]" in cm_command_wait
assert "cm_api_command_poll.status | default(0) | int == 404" in cm_command_wait
assert "cm_api_command_label | default('CM API command')" in cm_command_wait
assert "cm_api_command_request_timeout | default(10)" in cm_command_wait
assert "cm_api_command_timeout_help" in cm_command_wait
assert cm_command_wait.count(
    'connection: "{{ cm_api_command_connection | default(\'smart\') }}"'
) == 3
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
assert "cloudera.cloud.dw_connector_info:" in cdw_force_reset
assert "CDW recovery | Remove Trino Hive and Iceberg federation connectors" in cdw_force_reset
assert "cloudera.cloud.dw_connector:" in cdw_force_reset
assert "item.template | default('') | lower in ['hive', 'iceberg']" in cdw_force_reset
assert cdw_force_reset.count("when: ecs_cdw_force_reset_eligible | bool") == 3
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
assert "~ '|KDC_ERR|PREAUTH|CLIENT_NOT_FOUND|ImportCredentials'" in cdw_diagnostics
assert "~ '|KDC_ERR|PREAUTH|CLIENT_NOT_FOUND|ImportCredentials|Kerberos'" not in cdw_diagnostics
assert "Latest relevant Cloudera Manager Kerberos evidence:" in cdw_diagnostics
assert "CDW result=FAILED; workload snapshot=" in cdw_diagnostics
assert "Root-cause log evidence: metastore=" in cdw_diagnostics
assert "--field-selector=type=Warning" in cdw_diagnostics
assert "WAITING:.status.containerStatuses[*].state.waiting.reason" in cdw_diagnostics
assert "ready='}{.status.readyReplicas}" in cdw_diagnostics
assert "custom-columns=NAME:.metadata.name,STATUS:.status.phase" in cdw_diagnostics
assert "\n      - describe\n" not in cdw_diagnostics
assert "truncate(" not in cdw_diagnostics
assert "cut -c" not in cdw_diagnostics
cdw_diagnostic_tasks = yaml.safe_load(cdw_diagnostics)
cdw_boundary_report = next(
    task
    for task in cdw_diagnostic_tasks
    if task.get("name") == "CDW diagnostics | Report control-plane and Kerberos boundary"
)
cdw_kubernetes_report = next(
    task
    for task in cdw_diagnostic_tasks
    if task.get("name") == "Report failed CDW Kubernetes diagnostics"
)
assert len(cdw_boundary_report["ansible.builtin.debug"]["msg"]) == 5
assert len(cdw_kubernetes_report["ansible.builtin.debug"]["msg"]) == 6
assert "ecs_cdw_diagnostics_collected: true" in cdw_diagnostics
assert "state: present" not in cdw_diagnostics
assert "ipa-getkeytab" not in cdw_diagnostics
assert "ecs_data_service_cdw_reconcile_workload_ccache.yml" not in cdw_setup

cde_preflight = yaml.safe_load(
    (
        root
        / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cde_preflight.yml"
    ).read_text()
)
cde_tasks = {task.get("name"): task for task in cde_preflight}
cde_existing_report = str(
    cde_tasks["CDE | Report selected existing service without capacity mutation"][
        "ansible.builtin.debug"
    ]["msg"]
)
cde_absent_report = str(
    cde_tasks["CDE | Report absent service selected for creation"][
        "ansible.builtin.debug"
    ]["msg"]
)
assert "CDE Service: Existing resource selected for mutation-free reuse." in (
    cde_existing_report
)
assert "name={{ ecs_cde_service_name_effective }}" in cde_existing_report
assert "observed_status={{ ecs_cde_service_prior_status }}" in cde_existing_report
assert "Existing CPU and memory capacity will not be resized." in cde_existing_report
assert "CDE: ABSENT" in cde_absent_report
assert "name={{ ecs_cde_service_name_effective }}" in cde_absent_report
assert "status={{ ecs_cde_service_prior_status }}" in cde_absent_report
assert "action=CREATE" in cde_absent_report

cai_preflight = yaml.safe_load(
    (
        root
        / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_preflight.yml"
    ).read_text()
)
cai_tasks = {task.get("name"): task for task in cai_preflight}
cai_existing_report = str(
    cai_tasks["CAI | Report authoritative reusable workspace"][
        "ansible.builtin.debug"
    ]["msg"]
)
cai_absent_report = str(
    cai_tasks["CAI | Report absent workspace selected for creation"][
        "ansible.builtin.debug"
    ]["msg"]
)
assert "CAI Workbench: Existing workspace recognized and selected for reuse." in (
    cai_existing_report
)
assert "ecs_cai_existing_workspace.instanceName" in cai_existing_report
assert "ecs_cai_existing_workspace.instanceStatus" in cai_existing_report
assert "No rename or duplicate create is performed." in cai_existing_report
assert "CAI: ABSENT" in cai_absent_report
assert "name={{ ecs_cai_workspace_name_effective }}" in cai_absent_report
assert "status=Absent" in cai_absent_report
assert "action=CREATE" in cai_absent_report

cdw_followup = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_followup.yml"
).read_text()
cdw_vw = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_virtual_warehouse.yml"
).read_text()
cdw_dwx_module = (
    root / "ansible-playbooks/library/cdw_private_dwx.py"
).read_text()
cdw_start = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_start.yml"
).read_text()
data_services_runtime = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_services_runtime.yml"
).read_text()
assert "ecs_cdw_trino_vw_name" in cdw_followup
assert "'type': 'trino'" in cdw_followup
assert group_vars["ecs_cdw_virtual_warehouse_types"] == ["hive"]
assert "ecs_cdw_virtual_warehouse_types_effective" in cdw_followup
assert "difference(['hive', 'impala', 'trino'])" in cdw_followup
assert "'create-vw'" in cdw_vw
assert "'--resource-pool'" in cdw_vw
assert "ecs_cdw_vw_resource_pool" in cdw_vw
assert "'--t-shirt-size'" in cdw_vw
assert "ecs_cdw_vw_tshirt_size" in cdw_vw
assert "'--resource-template'" in cdw_vw
assert "ecs_cdw_vw_resource_template_ids[ecs_cdw_vw.type]" in cdw_vw
assert "'list-resource-templates'" in cdw_followup
assert "ecs_cdw_vw_resource_template_name" in cdw_followup
assert "lowResourceMode" not in data_services_runtime
assert '["CreateVwRequest"]["properties"]["resourceTemplate"]' in data_services_runtime
assert "operation: activate_environment" in cdw_start
assert "enableLowResourceMode: true" in cdw_start
assert "environment_crn:" in cdw_start
assert "'create-private-cluster'" in cdw_start
assert "'--low-resource-mode'" in cdw_start
assert "not (ecs_cdw_low_resource_mode | default(false) | bool)" in cdw_start
assert "'--impala-options'" in cdw_vw
assert "'--impala-ha-settings'" in cdw_vw
assert "'--autoscaling'" in cdw_vw
assert "'--additional-quota'" in cdw_vw
assert "'--impala-query-log'" not in cdw_vw
assert "'--no-impala-query-log'" not in cdw_vw
assert "Validate configured Impala Virtual Warehouse settings" in cdw_followup
assert "Validate configured Trino Virtual Warehouse settings" in cdw_followup
assert "ecs_cdw_trino_autoscaling | to_json" in cdw_vw
assert "ecs_cdw_trino_additional_quota | to_json" in cdw_vw
assert "ecs_cdw_vw_existing.virtual_warehouses | default([]) | length == 0" in cdw_vw
assert "Converge CDW Virtual Warehouses sequentially" in cdw_followup
assert "loop_var: ecs_cdw_vw" in cdw_followup
assert "running|stopped|suspended|failed|error" in cdw_vw
assert "ecs_data_service_cdw_reconcile_vw_ccaches.yml" not in cdw_followup
assert "'describe-dbc-config'" in cdw_followup
assert "'update-dbc'" in cdw_followup
assert "failed to acquire lease|already leased by operation" in cdw_followup
assert "Require database catalog FILE cache update" in cdw_followup
assert "'start-dbc'" in cdw_followup
assert "'--force-refresh'" in cdw_followup
assert "another operation[^\\\\n]*already in progress" in cdw_followup
assert "Require database catalog workload refresh" in cdw_followup
assert "ecs_cdw_catalog_initial_status" in cdw_followup
assert "stopped|suspended|deactivated" in cdw_followup
assert "Verify generated metastore FILE credential cache" in cdw_followup
assert "Verify converged database catalog FILE credential cache configuration" in cdw_followup
assert "No KCM server|default ccache.*KCM|KCM server" in cdw_followup
assert "'describe-vw-config'" in cdw_vw
assert "'update-vw'" in cdw_vw
assert "Require Hive pods to use FILE credential cache" in cdw_vw
assert "/dwx/api/v2/environments/" in cdw_dwx_module
assert "/llaps?start" in cdw_dwx_module
assert "/authenticate/callback/local" in cdw_dwx_module
assert "cdw_private_dwx:" in cdw_vw
assert "resourceTemplate" in cdw_vw
assert "cdp-pvt-session-token" in cdw_dwx_module
assert cdw_followup.count("ecs_cdw_dbc_file_ccache_config_effective.stdout") == 2
assert cdw_followup.count("ecs_cdw_dbc_file_ccache_config | to_json") == 2
assert cdw_vw.count("ecs_cdw_vw_file_ccache_config | to_json") == 1
assert cdw_followup.count(".get(\"KRB5CCNAME\", \"\")") == 3
assert "Read database catalog namespace pods for authoritative health" in cdw_followup
assert "Verify database catalog namespace health" in cdw_followup
assert 'required_apps = {"metastore", "hue-query-processor"}' in cdw_followup
assert 'any(owner.get("kind") == "Job" for owner in owners)' in cdw_followup
assert 'status.get("phase") != "Running"' in cdw_followup
assert 'ready != expected' in cdw_followup
assert 'waiting.get("reason")' in cdw_followup
assert "container.get('restartCount', 0)" in cdw_followup
assert "ecs_cdw_catalog_kubernetes_health.rc not in [0, 3]" in cdw_followup
assert "healthy metastore and Hue" in cdw_followup
assert "ecs_cdw_dbc_ccache_update.rc | default(1) == 0" in cdw_followup
cdw_followup_tasks = yaml.safe_load(cdw_followup)
cdw_followup_block = next(
    task["block"]
    for task in cdw_followup_tasks
    if task.get("name") == "CDW | Complete database catalog and Virtual Warehouses"
)
cdw_health_task = next(
    task
    for task in cdw_followup_block
    if task.get("name") == "Verify database catalog namespace health"
)
cdw_health_script = cdw_health_task["ansible.builtin.command"]["argv"][2]
crashloop_payload = {
    "items": [
        {
            "metadata": {
                "name": "metastore-0",
                "labels": {"app": "metastore"},
            },
            "spec": {"containers": [{"name": "metastore"}]},
            "status": {
                "phase": "Running",
                "containerStatuses": [
                    {
                        "name": "metastore",
                        "ready": False,
                        "restartCount": 12,
                        "state": {
                            "waiting": {"reason": "CrashLoopBackOff"},
                        },
                    }
                ],
            },
        },
        {
            "metadata": {
                "name": "hue-query-processor-0",
                "labels": {"app": "hue-query-processor"},
            },
            "spec": {"containers": [{"name": "hue-query-processor"}]},
            "status": {
                "phase": "Running",
                "containerStatuses": [
                    {
                        "name": "hue-query-processor",
                        "ready": True,
                        "restartCount": 0,
                        "state": {"running": {}},
                    }
                ],
            },
        },
    ]
}
crashloop_check = subprocess.run(
    [sys.executable, "-c", cdw_health_script],
    input=json.dumps(json.dumps(crashloop_payload)),
    text=True,
    capture_output=True,
)
assert crashloop_check.returncode == 3
assert "CrashLoopBackOff" in crashloop_check.stdout
assert "restarts=12" in crashloop_check.stdout
assert "failed_when: ecs_cdw_dbc_ccache_check.rc not in [0, 3]" in cdw_followup
assert (
    cdw_followup.index("Persist database catalog FILE credential cache through CDW API")
    < cdw_followup.index("\n    - name: Wait for default database catalog\n")
)
assert "Converge CDW Virtual Warehouses sequentially" in cdw_followup
assert "CDW VW | Wait for {{ ecs_cdw_vw.type }} terminal status" in cdw_vw
assert group_vars["ecs_cdw_vw_tshirt_size"] == "xsmall"
assert group_vars["ecs_cdw_low_resource_mode"] is True
assert group_vars["ecs_cdw_vw_resource_template_name"] == "Reduced resources"
assert group_vars["ecs_cdw_hive_reduced_executor_memory_max_gib"] == 64
assert "CDW VW | Verify {{ ecs_cdw_vw.type }} reduced-resource memory" in cdw_vw
assert '"query-executor"' in cdw_vw
assert "actual_gib <= limit_gib" in cdw_vw
assert "Delete this creation-time Virtual Warehouse" in cdw_vw
assert group_vars["ecs_cdw_vw_resource_pool"] == "root.{{ ecs_cdp_environment_name }}.cdw"
assert group_vars["ecs_cdw_impala_ha_settings"]["highAvailabilityMode"] == "DISABLED"
assert group_vars["ecs_cdw_impala_ha_settings"]["enableShutdownOfCoordinator"] is False
assert group_vars["ecs_cdw_impala_autoscaling"]["minClusters"] == 1
assert group_vars["ecs_cdw_impala_autoscaling"]["maxClusters"] == 5
assert group_vars["ecs_cdw_impala_autoscaling"]["autoSuspendTimeoutSeconds"] == 300
assert group_vars["ecs_cdw_impala_autoscaling"]["impalaScaleUpDelaySeconds"] == 20
assert group_vars["ecs_cdw_impala_autoscaling"]["impalaScaleDownDelaySeconds"] == 300
assert group_vars["ecs_cdw_impala_additional_quota"] == {"cpu": 0.0, "memory": 0}
assert "ecs_cdw_impala_query_log" not in group_vars
assert group_vars["ecs_cdw_trino_autoscaling"] == {}
assert group_vars["ecs_cdw_trino_additional_quota"] == {"cpu": 0.0, "memory": 0}
assert group_vars["ecs_cdw_catalog_kubernetes_health_fallback"] is True
assert group_vars["ecs_cdw_vw_krb5ccname"] == "FILE:/tmp/krb5cc_cdw"
assert group_vars["ecs_cdw_vw_file_ccache_applications"]["hive"] == [
    "hiveserver2",
    "query-coordinator",
    "query-executor",
]
assert group_vars["ecs_cdw_vw_file_ccache_reconcile_types"] == ["hive", "impala"]
assert (
    "format"
    not in group_vars["ecs_cdw_dbc_file_ccache_config"]["applicationConfigs"][
        "metastore"
    ]["configBlocks"][0]
)
assert (
    group_vars["ecs_cdw_dbc_file_ccache_config"]["applicationConfigs"]["metastore"][
        "configBlocks"
    ][0]
    ["content"]["keyValues"]["KRB5CCNAME"]
    == "{{ ecs_cdw_workload_krb5ccname }}"
)
assert (
    "format"
    not in group_vars["ecs_cdw_vw_file_ccache_config"]["commonConfigs"][
        "configBlocks"
    ][0]
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
    if task.get("name") == "Require human Model Registry creator CRN"
)
creator_assert_text = str(model_registry_creator_assert)
assert ":user:" in creator_assert_text
assert ":machineuser:" in creator_assert_text
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
