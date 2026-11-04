#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ansible_dir="${repo_root}/ansible-playbooks"
inventory="${ansible_dir}/inventory.ini"
template="${ansible_dir}/templates/base_cluster_cluster_spec.j2"
validation_tasks="${ansible_dir}/common_tasks/validate_ranger_directory_config.yml"
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
        base_cluster_kafka_metadata_store_effective: Zookeeper
        base_master_fqdn: master.example.invalid
        base_worker_fqdns: []
        base_cluster_hosts: []
      no_log: true

    - name: Validate Ranger directory variables
      ansible.builtin.include_tasks: "{{ ranger_validation_tasks }}"

    - name: Render Ranger configuration twice
      ansible.builtin.set_fact:
        rendered_cluster_spec_first: "{{ lookup('template', ranger_cluster_spec_template) | from_yaml }}"
        rendered_cluster_spec_second: "{{ lookup('template', ranger_cluster_spec_template) | from_yaml }}"
      no_log: true

    - name: Select rendered Ranger service and role groups
      ansible.builtin.set_fact:
        rendered_ranger_service: >-
          {{
            rendered_cluster_spec_first.services
            | selectattr('type', 'equalto', 'RANGER')
            | first
          }}
        rendered_ranger_role_groups: >-
          {{
            (
              rendered_cluster_spec_first.services
              | selectattr('type', 'equalto', 'RANGER')
              | first
            ).role_groups
          }}
      no_log: true

    - name: Verify provider-specific Ranger directory rendering
      ansible.builtin.assert:
        that:
          - rendered_cluster_spec_first == rendered_cluster_spec_second
          - base_cluster_ranger_usersync_provider_effective == expected_provider
          - (base_cluster_ranger_usersync_configure_effective | bool) == (expected_configure | bool)
          - >-
            (
              rendered_ranger_role_groups
              | selectattr('type', 'equalto', 'RANGER_ADMIN')
              | list
              | length
            ) == 1
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
            or base_cluster_ranger_usersync_ldap_url == expected_ldap_url
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_admin_base_dn == expected_base_dn
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_usersync_user_search_base == expected_user_base
          - >-
            not (expected_configure | bool)
            or base_cluster_ranger_usersync_group_search_base == expected_group_base
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_USERSYNC')
                | first
              ).config['ranger.usersync.enabled']
              == 'true'
            )
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_USERSYNC')
                | first
              ).config['ranger.usersync.ldap.user.searchfilter']
              == expected_user_filter
            )
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_USERSYNC')
                | first
              ).config['ranger.usersync.group.searchfilter']
              == expected_group_filter
            )
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_USERSYNC')
                | first
              ).config['ranger.usersync.ldap.starttls']
              == (expected_starttls | bool | lower)
            )
          - >-
            not (expected_configure | bool)
            or (
              (
                rendered_ranger_role_groups
                | selectattr('type', 'equalto', 'RANGER_USERSYNC')
                | first
              ).config['ranger_usersync_ldap_ldapbindpassword']
              == lookup('env', 'RANGER_TEST_BIND_PASSWORD')
            )
          - >-
            not (expected_configure | bool)
            or (
              base_cluster_ranger_usersync_role_config
              | dict2items
              | map(attribute='key')
              | difference(expected_usersync_keys)
              | length
            ) == 0
          - >-
            not (expected_configure | bool)
            or (
              expected_usersync_keys
              | difference(
                  base_cluster_ranger_usersync_role_config
                  | dict2items
                  | map(attribute='key')
                  | list
                )
              | length
            ) == 0
      no_log: true

    - name: Report mapping verification
      ansible.builtin.debug:
        msg: "Ranger {{ expected_provider }} mapping verified"
YAML

expected_usersync_keys='["ranger.usersync.enabled","ranger.usersync.source.impl.class","ranger.usersync.ldap.url","ranger.usersync.ldap.binddn","ranger_usersync_ldap_ldapbindpassword","ranger.usersync.ldap.searchBase","ranger.usersync.ldap.starttls","ranger.usersync.ldap.deltasync","ranger.usersync.ldap.user.searchbase","ranger.usersync.ldap.user.searchscope","ranger.usersync.ldap.user.objectclass","ranger.usersync.ldap.user.searchfilter","ranger.usersync.ldap.user.nameattribute","ranger.usersync.ldap.user.groupnameattribute","ranger.usersync.group.searchbase","ranger.usersync.group.searchscope","ranger.usersync.group.objectclass","ranger.usersync.group.searchfilter","ranger.usersync.group.nameattribute","ranger.usersync.group.memberattributename","ranger.usersync.group.searchenabled","ranger.usersync.group.usermapsyncenabled","ranger.usersync.ldap.referral","ranger.usersync.ldap.username.caseconversion","ranger.usersync.ldap.groupname.caseconversion","ranger.usersync.ldap.grouphierarchylevels","ranger.usersync.pagedresultsenabled","ranger.usersync.user.searchenabled","ranger.usersync.unix.backend"]'

run_provider() {
  local provider="$1"
  local expected_configure="$2"
  local expected_authentication_method="$3"
  local expected_admin_url_key="$4"
  local expected_user_filter="$5"
  local expected_group_filter="$6"
  local expected_starttls="$7"
  local expected_ldap_url="$8"
  local expected_base_dn="$9"
  local expected_user_base="${10}"
  local expected_group_base="${11}"
  shift 11

  local output
  output="$(
    ansible-playbook \
      -i "${inventory}" \
      "${playbook}" \
      -e "ranger_cluster_spec_template=${template}" \
      -e "ranger_validation_tasks=${validation_tasks}" \
      -e "base_cluster_ranger_usersync_provider=${provider}" \
      -e "base_cluster_ranger_usersync_bind_password={{ lookup('env', 'RANGER_TEST_BIND_PASSWORD') }}" \
      -e "expected_provider=${provider}" \
      -e "expected_configure=${expected_configure}" \
      -e "expected_authentication_method=${expected_authentication_method}" \
      -e "expected_admin_url_key=${expected_admin_url_key}" \
      -e "expected_user_filter=${expected_user_filter}" \
      -e "expected_group_filter=${expected_group_filter}" \
      -e "expected_starttls=${expected_starttls}" \
      -e "expected_ldap_url=${expected_ldap_url}" \
      -e "expected_base_dn=${expected_base_dn}" \
      -e "expected_user_base=${expected_user_base}" \
      -e "expected_group_base=${expected_group_base}" \
      -e "{\"expected_usersync_keys\":${expected_usersync_keys}}" \
      "$@" 2>&1
  )"
  printf '%s\n' "${output}"
  if grep -Fq "${RANGER_TEST_BIND_PASSWORD}" <<<"${output}"; then
    echo "Ranger bind secret leaked into Ansible output" >&2
    return 1
  fi
}

export RANGER_TEST_BIND_PASSWORD
RANGER_TEST_BIND_PASSWORD="$(openssl rand -hex 24)"

run_provider freeipa true LDAP ranger.ldap.url '(uid=*)' \
  '(objectClass=ipausergroup)' true \
  ldap://ipa01.directory.lab.example:389 \
  dc=directory,dc=lab,dc=example \
  cn=users,cn=accounts,dc=directory,dc=lab,dc=example \
  cn=groups,cn=accounts,dc=directory,dc=lab,dc=example \
  -e identity_provider=freeipa \
  -e ipaserver_domain=directory.lab.example \
  -e ipa_kdc_host=ipa01.directory.lab.example \
  -e cm_ldap_scheme=ldap \
  -e cm_ldap_port=389 \
  -e cm_ldap_starttls=true \
  -e base_cluster_ranger_usersync_truststore_path=

run_provider ad true ACTIVE_DIRECTORY ranger.ldap.ad.url '(sAMAccountName=*)' \
  '(objectClass=group)' false \
  ldaps://dc02.directory.example.net:636 \
  DC=directory,DC=example,DC=net \
  'OU=Platform Users,DC=directory,DC=example,DC=net' \
  'OU=Platform Groups,DC=directory,DC=example,DC=net' \
  -e identity_provider=ad \
  -e ad_domain=directory.example.net \
  -e ad_kdc_host=dc02.directory.example.net \
  -e 'ad_ldap_bind_dn=CN=svc-ranger,OU=Service Accounts,DC=directory,DC=example,DC=net' \
  -e 'ad_ldap_user_search_base=OU=Platform Users,DC=directory,DC=example,DC=net' \
  -e 'ad_ldap_group_search_base=OU=Platform Groups,DC=directory,DC=example,DC=net' \
  -e cm_ldap_scheme=ldaps \
  -e cm_ldap_port=636 \
  -e base_cluster_ranger_usersync_truststore_path=

run_provider external true LDAP ranger.ldap.url '(employeeType=platform)' \
  '(businessCategory=data)' false \
  ldaps://ldap03.example.org:1636 \
  dc=example,dc=org \
  ou=people,dc=example,dc=org \
  ou=groups,dc=example,dc=org \
  -e identity_provider=freeipa \
  -e base_cluster_ranger_usersync_external_ldap_url=ldaps://ldap03.example.org:1636 \
  -e 'base_cluster_ranger_usersync_external_bind_dn=uid=svc-ranger,ou=system,dc=example,dc=org' \
  -e base_cluster_ranger_usersync_external_base_dn=dc=example,dc=org \
  -e 'base_cluster_ranger_usersync_external_user_search_base=ou=people,dc=example,dc=org' \
  -e 'base_cluster_ranger_usersync_external_group_search_base=ou=groups,dc=example,dc=org' \
  -e 'base_cluster_ranger_usersync_external_sync_user_search_filter=(employeeType=platform)' \
  -e 'base_cluster_ranger_usersync_external_sync_group_search_filter=(businessCategory=data)' \
  -e base_cluster_ranger_usersync_truststore_path=

run_provider none false "" "" "" "" false "" "" "" "" \
  -e identity_provider=freeipa

validation_output="${tmp_dir}/validation-failure.log"
if RANGER_TEST_BIND_PASSWORD="" ansible-playbook \
  -i "${inventory}" \
  "${playbook}" \
  -e "ranger_cluster_spec_template=${template}" \
  -e "ranger_validation_tasks=${validation_tasks}" \
  -e base_cluster_ranger_usersync_provider=freeipa \
  -e identity_provider=freeipa \
  -e base_cluster_ranger_usersync_bind_password= \
  -e expected_provider=freeipa \
  -e expected_configure=true \
  -e expected_authentication_method=LDAP \
  -e expected_admin_url_key=ranger.ldap.url \
  -e 'expected_user_filter=(uid=*)' \
  -e 'expected_group_filter=(objectClass=ipausergroup)' \
  -e expected_starttls=false \
  -e "{\"expected_usersync_keys\":${expected_usersync_keys}}" \
  >"${validation_output}" 2>&1; then
  echo "Expected missing Ranger bind credential validation to fail" >&2
  exit 1
fi

if ansible-playbook \
  -i "${inventory}" \
  "${playbook}" \
  -e "ranger_cluster_spec_template=${template}" \
  -e "ranger_validation_tasks=${validation_tasks}" \
  -e base_cluster_ranger_usersync_provider=ad \
  -e identity_provider=freeipa \
  -e "base_cluster_ranger_usersync_bind_password={{ lookup('env', 'RANGER_TEST_BIND_PASSWORD') }}" \
  -e expected_provider=ad \
  -e expected_configure=true \
  -e expected_authentication_method=ACTIVE_DIRECTORY \
  -e expected_admin_url_key=ranger.ldap.ad.url \
  -e 'expected_user_filter=(sAMAccountName=*)' \
  -e 'expected_group_filter=(objectClass=group)' \
  -e expected_starttls=false \
  -e "{\"expected_usersync_keys\":${expected_usersync_keys}}" \
  >"${validation_output}" 2>&1; then
  echo "Expected mismatched Ranger/identity providers to fail" >&2
  exit 1
fi

if grep -Fq "${RANGER_TEST_BIND_PASSWORD}" "${validation_output}"; then
  echo "Ranger bind secret leaked into validation failure output" >&2
  exit 1
fi

echo "Ranger LDAP/AD provider rendering checks passed"
