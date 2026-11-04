#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ansible_dir="${repo_root}/ansible-playbooks"
inventory="${ansible_dir}/inventory.ini"
template="${ansible_dir}/roles/cdh_base_cluster/templates/base_cluster_cluster_spec.j2"
tmp_dir="$(mktemp -d)"
playbook="${tmp_dir}/ranger-provider-render.yml"
trap 'rm -rf "${tmp_dir}"' EXIT

cat >"${playbook}" <<'YAML'
---
- name: Validate Ranger LDAP provider rendering
  hosts: cm-node
  connection: local
  gather_facts: false
  tasks:
    - name: Resolve cluster template prerequisites
      ansible.builtin.set_fact:
        base_cluster_kafka_metadata_store_effective: >-
          {{ 'KRaft' if base_cluster_kafka_metadata_store | lower == 'kraft' else 'Zookeeper' }}
        base_master_fqdn: >-
          {%- set hostname = hostvars[groups[base_cluster_master_group][0]].cldr_hostname -%}
          {{ hostname if hostname.endswith('.' ~ cluster_domain) else hostname ~ '.' ~ cluster_domain }}
        base_worker_fqdns: >-
          {{
            groups[base_cluster_worker_group]
            | map('extract', hostvars, 'cldr_hostname')
            | map('regex_replace', '$', '.' ~ cluster_domain)
            | list
          }}
        base_cluster_hosts: []
      no_log: true

    - name: Evaluate Ranger LDAP configuration
      ansible.builtin.set_fact:
        rendered_cluster_spec: "{{ lookup('template', ranger_cluster_spec_template) | from_yaml }}"
      no_log: true

    - name: Select rendered Ranger role groups
      ansible.builtin.set_fact:
        rendered_ranger_role_groups: >-
          {{
            (
              rendered_cluster_spec.services
              | selectattr('type', 'equalto', 'RANGER')
              | first
            ).role_groups
          }}
      no_log: true

    - name: Verify provider-specific Ranger LDAP rendering
      ansible.builtin.assert:
        that:
          - base_cluster_ranger_usersync_provider_effective == expected_provider
          - (base_cluster_ranger_usersync_configure_effective | bool) == (expected_configure | bool)
          - >-
            (
              rendered_ranger_role_groups
              | selectattr('type', 'equalto', 'RANGER_USERSYNC')
              | list
              | length > 0
            ) == (expected_configure | bool)
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_ADMIN')
                | first
              ).config.ranger_authentication_method
              == expected_authentication_method
            )
          - >-
            not (expected_configure | bool)
            or expected_admin_url_key in (
              rendered_ranger_role_groups
              | selectattr('type', 'equalto', 'RANGER_ADMIN')
              | first
            ).config
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_USERSYNC')
                | first
              ).config['ranger.usersync.group.objectclass']
              == expected_group_object_class
            )
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_admin_base_dn | string | length > 0
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_usersync_ldap_url | string | length > 0
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_usersync_bind_dn | string | length > 0
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_usersync_bind_password | string | length > 0
      no_log: true
YAML

run_provider() {
  local provider="$1"
  local expected_configure="$2"
  local expected_authentication_method="$3"
  local expected_admin_url_key="$4"
  local expected_group_object_class="$5"
  shift 5

  ansible-playbook \
    -i "${inventory}" \
    "${playbook}" \
    -e "ranger_cluster_spec_template=${template}" \
    -e "base_cluster_ranger_usersync_provider=${provider}" \
    -e "expected_provider=${provider}" \
    -e "expected_configure=${expected_configure}" \
    -e "expected_authentication_method=${expected_authentication_method}" \
    -e "expected_admin_url_key=${expected_admin_url_key}" \
    -e "expected_group_object_class=${expected_group_object_class}" \
    "$@"
}

run_provider freeipa true LDAP ranger.ldap.url ipausergroup
run_provider ad true ACTIVE_DIRECTORY ranger.ldap.ad.url group
run_provider external true LDAP ranger.ldap.url groupOfNames \
  -e base_cluster_ranger_usersync_external_ldap_url=ldaps://ldap.example.com:636 \
  -e 'base_cluster_ranger_usersync_external_bind_dn=uid=svc-ranger,ou=system,dc=example,dc=com' \
  -e base_cluster_ranger_usersync_external_bind_password=test-password \
  -e base_cluster_ranger_usersync_external_base_dn=dc=example,dc=com \
  -e 'base_cluster_ranger_usersync_external_user_search_base=ou=people,dc=example,dc=com' \
  -e 'base_cluster_ranger_usersync_external_group_search_base=ou=groups,dc=example,dc=com'
run_provider none false "" "" ""

ansible-playbook \
  -i "${inventory}" \
  "${playbook}" \
  -e "ranger_cluster_spec_template=${template}" \
  -e base_cluster_ranger_usersync_provider=freeipa \
  -e base_cluster_ranger_usersync_enabled=false \
  -e expected_provider=freeipa \
  -e expected_configure=false \
  -e expected_authentication_method="" \
  -e expected_admin_url_key="" \
  -e expected_group_object_class=""

echo "Ranger LDAP provider rendering checks passed"
