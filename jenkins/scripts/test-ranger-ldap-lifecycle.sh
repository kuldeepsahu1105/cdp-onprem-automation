#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
group_vars = yaml.safe_load((root / "ansible-playbooks/group_vars/all.yml").read_text())
tasks = (root / "ansible-playbooks/roles/cdh_base_cluster/tasks/setup_base_cluster.yml").read_text()
template = (
    root / "ansible-playbooks/roles/cdh_base_cluster/templates/base_cluster_cluster_spec.j2"
).read_text()
reconcile = (
    root / "ansible-playbooks/roles/cdh_base_cluster/tasks/reconcile_cm_config_api.yml"
).read_text()
validation = (
    root / "ansible-playbooks/roles/cdh_base_cluster/tasks/validate_ranger_directory_config.yml"
).read_text()

assert group_vars["base_cluster_ranger_usersync_enabled"] is True
assert group_vars["base_cluster_ranger_usersync_provider"] == "auto"
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

admin = "Configure Ranger Admin LDAP authentication"
usersync = "Configure Ranger UserSync LDAP provider"
assert admin in tasks
assert usersync in tasks
assert tasks.index(admin) < tasks.index(usersync)
assert "Read Ranger role config groups for LDAP integration" in tasks
assert "RANGER_ADMIN" in tasks
assert "RANGER_USERSYNC" in tasks
assert "base_cluster_ranger_usersync_configure_effective | bool" in tasks
assert "ranger_ldap_ad_bind_password" in tasks
assert "ranger_ldap_bind_password" in tasks
assert "ranger_usersync_ldap_ldapbindpassword" in tasks
assert "cm_config_secret_names" in tasks
assert "cm_config_require_known_names: true" in tasks
assert "Restore Ranger Admin local authentication when directory integration is disabled" in tasks
assert "Disable existing Ranger UserSync when directory integration is disabled" in tasks
assert 'ranger.usersync.enabled: "false"' in tasks
assert "Check Ranger directory truststore on the Ranger host" in tasks
assert "Validate Ranger directory integration" in tasks
assert "no_log: true" in tasks
assert "base_cluster_required_config_changed" in tasks
assert "base_cluster_existing_restart_required" in tasks
assert "cm_config_desired | dict2items" in reconcile
assert "cm_config_require_known_names" in reconcile
assert "difference(" in reconcile
assert "base_cluster_required_config_changed" in reconcile
assert "no_log:" in reconcile
assert "STARTTLS is valid only with ldap://" in validation
assert "identity_provider_effective" in validation

assert "base_cluster_ranger_usersync_configure_effective | bool" in template
assert "base_cluster_ranger_admin_ldap_config.items()" in template
assert "base_cluster_ranger_usersync_role_config.items()" in template

admin_config = str(group_vars["base_cluster_ranger_admin_ldap_config"])
assert "ranger_authentication_method" in admin_config
assert "ranger.ldap.ad.url" in admin_config
assert "ranger.ldap.url" in admin_config
usersync_config = str(group_vars["base_cluster_ranger_usersync_role_config"])
for key in (
    "ranger.usersync.enabled",
    "ranger.usersync.source.impl.class",
    "ranger.usersync.ldap.starttls",
    "ranger.usersync.ldap.deltasync",
    "ranger.usersync.ldap.user.searchfilter",
    "ranger.usersync.group.searchfilter",
    "ssl_client_truststore_location",
):
    assert key in usersync_config

print("Ranger LDAP/AD lifecycle regression checks passed")
PY
