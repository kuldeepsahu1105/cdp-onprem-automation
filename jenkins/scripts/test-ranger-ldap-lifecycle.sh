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

assert group_vars["base_cluster_ranger_usersync_enabled"] is True
assert group_vars["base_cluster_ranger_usersync_provider"] == "auto"
assert group_vars["base_cluster_ranger_usersync_provider_allowed"] == [
    "auto",
    "freeipa",
    "ad",
    "external",
    "none",
]

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

assert "base_cluster_ranger_usersync_configure_effective | bool" in template
assert "base_cluster_ranger_admin_ldap_config.items()" in template
assert "base_cluster_ranger_usersync_ldap_url" in template
assert "base_cluster_ranger_usersync_bind_dn" in template
assert "base_cluster_ranger_usersync_bind_password" in template
assert "ranger.usersync.source.impl.class" in template

admin_config = str(group_vars["base_cluster_ranger_admin_ldap_config"])
assert "ranger_authentication_method" in admin_config
assert "ranger.ldap.ad.url" in admin_config
assert "ranger.ldap.url" in admin_config

print("Ranger LDAP lifecycle regression checks passed")
PY
