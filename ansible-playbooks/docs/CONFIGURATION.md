# Configuration Guide

This guide documents every operator-facing setting in
[`config.yml`](../config.yml), the accepted values, and when to provide an
override. Keep deployment choices in `config.yml`; keep passwords in Vault,
Jenkins password parameters, or another protected extra-vars source.

## Precedence

Values are resolved from lowest to highest priority:

1. `group_vars/all.yml` - stable defaults and derived values
2. `config.yml` - deployment-specific choices
3. extra vars - Jenkins overrides, `ANSIBLE_EXTRA_VARS`, or `-e`

An empty string normally means "derive or use the stable default." An empty
list means "do not add an override." Do not replace a generated URL list
unless the table below says the list is a complete replacement.

## Required choices by deployment type

| Deployment | Required input |
|---|---|
| FreeIPA | Keep `identity_provider: auto` with an `[ipaserver]` inventory group, or set `freeipa`; set `ipaserver_domain` |
| Active Directory | Set `identity_provider: ad`, `ad_domain`, `ad_kdc_host`, DNS servers, AD account names/DNs, and the secrets described below |
| Terraform/AWS | Keep `deployment_environment: auto` or set `aws`; Terraform generates `inventory.ini` |
| Existing/bare-metal hosts | Set `deployment_environment: baremetal`; copy `inventory.example.ini` to `inventory.ini` and replace every example host/address |
| Base CDH only | Configure base inventory groups and `base_cluster_install_services`; leave ECS disabled or omit ECS groups |
| ECS | Provide ECS inventory groups and enable `ecs_deploy_enabled`; enable individual data services only when required |

## Active Directory credentials

Three credential purposes are supported:

| Variable | Purpose | Required behavior |
|---|---|---|
| `ad_join_user` | Joins Linux hosts to the AD realm | Required for AD identity setup |
| `ad_join_password` | Password for `ad_join_user` | Required; no secure value should be committed |
| `ad_kdc_admin_user` | Imported into CM as the Kerberos account manager | Defaults to `ad_join_user`; provide a separate delegated account when available |
| `ad_kdc_admin_password` | Password used by CM `importAdminCredentials` | Defaults to `ad_join_password`; provide when the KDC account differs |
| `ad_ldap_bind_dn` | Full LDAP bind DN used by CM to search AD | Required when `cm_ldap_enabled: true` |
| `ad_ldap_bind_password` | Password for the LDAP bind DN | Defaults to `ad_join_password`; provide when the bind account differs |

### Jenkins

Use the masked Jenkins parameters:

- `AD_JOIN_USER` and `AD_JOIN_PASSWORD`
- `AD_KDC_ADMIN_USER` and `AD_KDC_ADMIN_PASSWORD`
- `AD_LDAP_BIND_DN` and `AD_LDAP_BIND_PASSWORD`

Empty KDC/LDAP password parameters inherit `AD_JOIN_PASSWORD`. Non-secret AD
topology and search-base values can be placed in `ANSIBLE_GROUP_VARS_YAML`.
Jenkins parameter values override `config.yml`.

### CLI or wrapper with Vault

Create an encrypted file outside source control:

```yaml
# secrets.vault.yml
ad_join_password: "replace-me"
ad_kdc_admin_password: "replace-me"
ad_ldap_bind_password: "replace-me"
```

```bash
ansible-vault encrypt secrets.vault.yml
export ANSIBLE_VAULT_PASSWORD_FILE=/secure/path/vault-password
export ANSIBLE_EXTRA_VARS='@secrets.vault.yml'
DEPLOY_PHASE=all ./pvc_setup.sh
```

For one direct playbook:

```bash
ansible-playbook -i inventory.ini 11_identity_setup.yml \
  -e @config.yml -e @secrets.vault.yml --ask-vault-pass
```

## 1. Environment and identity

| Variable | Accepted values/default | What to provide and what it does |
|---|---|---|
| `identity_provider` | `auto` (default), `freeipa`, `ad` | `auto` selects FreeIPA when `[ipaserver]` has a host, otherwise AD when `ad_kdc_host` is set. Use an explicit value when inventory alone must not decide. |
| `deployment_environment` | `auto` (default), `aws`, `baremetal` | Controls DNS/network assumptions. `auto` detects AWS metadata; `baremetal` expects private routing or a configured bastion. |
| `ipaserver_domain` | DNS domain; default `cldrsetup.local` | FreeIPA DNS domain and source for the uppercase Kerberos realm. Replace it for every non-lab deployment. |
| `ad_domain` | AD DNS domain; default example `corp.example.com` | Required for AD. It becomes the cluster domain and uppercase Kerberos realm. |
| `ad_kdc_host` | FQDN or IP; empty by default | Required for AD. Empty prevents AD auto-detection. Prefer a resolvable domain controller FQDN. |
| `ad_dns_servers` | YAML list; defaults to `ad_kdc_host` | DNS resolvers written for AD clients. Provide all reachable AD DNS server IPs/FQDNs. |
| `ad_join_user` | Account name; default `svc-cloudera-join` | Account used by realm join. Pair with secret `ad_join_password`. |
| `ad_computer_ou` | Empty or AD distinguished name | Empty uses the default Computers container; otherwise places joined computer objects in this OU. |
| `ad_kdc_admin_user` | Account name; defaults to `ad_join_user` | Account CM uses to create/regenerate Kerberos principals. |
| `ad_ldap_bind_dn` | LDAP distinguished name | CM LDAP search account. Replace every `corp.example.com` example component. |
| `ad_ldap_user_search_base` | LDAP distinguished name | Base under which CM searches for users. |
| `ad_ldap_group_search_base` | LDAP distinguished name | Base under which CM searches for groups. |
| `extra_dns_search_domains` | YAML list; default `[]` | Appends search domains to environment-derived DNS configuration. |
| `extra_dns_nameservers` | YAML list; default `[]` | Appends additional resolver addresses. |
| `identity_dns_external_probe_host` | FQDN, empty, or `"off"` | External name checked after DNS cutover. Empty uses the regional RHUI name on RHEL/AWS, `archive.cloudera.com` on other AWS hosts, and skips the public check outside AWS. Use an internal mirror FQDN for restricted networks or quoted `"off"` to disable explicitly. |
| `dns_manage_networkmanager_resolv_conf` | Boolean; `true` | On RHEL 8/9, installs a NetworkManager `dns=none` drop-in so DHCP, NetworkManager, and identity installers do not replace the Ansible-managed `/etc/resolv.conf`. Set false only when another resolver manager owns the file. Ubuntu uses netplan instead. |

## 2. Product versions and repositories

Version strings must match artifacts available to your authenticated Cloudera
archive account. Numeric build IDs must correspond to the selected release.

| Variable | Default | What it controls |
|---|---|---|
| `java_version` | `"17"` | JDK installed on managed hosts. |
| `python_version` | `"3.11"` | Preferred target Python package version; Ansible still uses each host's configured `ansible_python_interpreter`. |
| `postgresql_version` | `18` | PostgreSQL server/client target version. |
| `postgres_jdbc_version` | `"42.7.10"` | JDBC driver downloaded for CM services. |
| `cm_version` | `"7.13.2.10000"` | Cloudera Manager package/repository version. |
| `cm_numeric_version` | `"713210000"` | Numeric CM build path used by archive URLs; update with `cm_version`. |
| `cdh_version` | `"7.3.2.10000"` | Runtime parcel version. |
| `cdh_numeric_version` | `"82216952"` | CDH parcel build identifier; update with `cdh_version`. |
| `cdv_version` | `"8.0.7"` | Data Visualization CSD/parcel release. |
| `cfm_version` | `"2.1.7.3004"` | Flow Management CSD/parcel release. |
| `cfm_nifi_app_version` | `"1.28.1"` | NiFi application segment used in CSD filenames. |
| `ecs_pvc_ds_version` | `"1.5.5-h3300"` | ECS/CDP Private Cloud Data Services repository tag. |
| `cm_repo_source` | `public` or `internal` | `public` installs from the Cloudera archive; `internal` builds/uses the CM-host mirror. |
| `cm_parcel_repo_urls_override` | `[]` or list of directory URLs | Non-empty **replaces the entire** CM parcel repository list. Include every CDH/CDV/CFM/ECS repository required. |
| `cm_csd_urls_override` | `[]` or list of `.jar` URLs | Non-empty replaces generated CSD downloads. Include every required CSD JAR. |
| `cm_parcel_repo_extra_urls` | `[]` or list of directory URLs | Appends repositories without replacing generated URLs. Use this for optional/custom parcels. |
| `cm_parcel_repo_include_intel_mkl` | Boolean; `true` | Adds the Intel MKL parcel repository. Disable when not required or unavailable. |
| `cm_parcel_repo_include_ecs_parcel` | Boolean; `true` | Adds pinned ECS and required ECS `latest` repository candidates. |
| `cm_parcel_repo_include_cdv_parcel` | Boolean; `true` | Adds the pinned Data Visualization parcel repository. |
| `cm_parcel_repo_include_cfm_parcel` | Boolean; `true` | Adds the pinned Flow Management parcel repository used by NiFi services. |

Repository URLs must be directories for CM parcel configuration; CSD override
entries must be complete `.jar` URLs. See
[REFERENCE.md](REFERENCE.md#cmcdh-repository-source) for generated URL shapes.

## 3. Base cluster

| Variable | Accepted values/default | What it does |
|---|---|---|
| `cdh_basecluster_name` | Name; `CDH-Cluster` | Cluster name created in CM. |
| `base_cluster_master_group` | Inventory group; `base-masters` | Hosts eligible for master roles. |
| `base_cluster_worker_group` | Inventory group; `base-workers` | Hosts eligible for worker roles and parcel OS detection. |

`base_cluster_install_services` controls service creation. Set a value to
`true` to include that service in the cluster specification:

| Key | Default | Effect |
|---|---|---|
| `core_settings` | `true` | Applies cluster-wide baseline settings. |
| `zookeeper` | `true` | Installs ZooKeeper; required by most distributed services. |
| `hdfs` | `true` | Installs HDFS storage roles. |
| `ozone` | `true` | Installs Ozone object storage roles. |
| `yarn` | `true` | Installs YARN resource management. |
| `tez` | `true` | Enables the Tez execution engine. |
| `hive` | `true` | Installs Hive services and metadata integration. |
| `hive_on_tez` | `true` | Configures Hive to use Tez; requires Hive and Tez. |
| `hbase` | `true` | Installs HBase; requires ZooKeeper and HDFS. |
| `hue` | `true` | Installs the Hue web application. |
| `iceberg` | `false` | Enables Iceberg-related service/configuration where supported. |
| `replication` | `false` | Enables replication service roles. |
| `impala` | `true` | Installs Impala query services. |
| `kafka` | `true` | Installs Kafka brokers. |
| `atlas` | `true` | Installs Atlas metadata/governance services. |
| `ranger` | `true` | Installs Ranger authorization services. |
| `nifi` | `false` | Installs NiFi; also requires compatible CFM CSD/parcel artifacts. |
| `nifi_registry` | `false` | Installs NiFi Registry; also requires compatible CFM artifacts. |
| `dataviz` | `false` | Installs Data Visualization; also requires compatible CDV artifacts. |
| `phoenix` | `false` | Installs Phoenix components where supported by the selected runtime. |
| `knox` | `true` | Installs Knox gateway services. |
| `solr` | `true` | Installs Solr search services. |

Keep dependency services enabled unless you intentionally provide an existing
equivalent. Unsupported version/service combinations fail during cluster
template validation rather than being silently ignored.

## 4. Cloudera Manager security integrations

| Variable | Accepted values/default | What it does |
|---|---|---|
| `autotls_enabled` | Boolean; `true` | Enables CM Auto-TLS orchestration. `false` leaves CM on its existing transport. |
| `cm_autotls_force_run` | Boolean; `false` | Forces `generateCmca` even when CM reports Auto-TLS configured. Use only for intentional certificate regeneration. |
| `use_freeipa_for_crt_mgmt` | Boolean/expression; derived from identity | When true, requires and trusts `/etc/ipa/ca.crt` during Auto-TLS. Set false for CM-generated CA without FreeIPA trust. |
| `cm_private_key_path` | Path or empty | Auto-TLS SSH-key provisioning key. Empty auto-discovers `sshkey.pem` or the Ansible SSH key. |
| `cm_priv_key_passphrase` | Secret string or empty | Passphrase for `cm_private_key_path`; leave empty for an unencrypted key. Prefer Vault/secret input. |
| `cm_srvr_sudo_user` | User; `root` | Remote sudo-capable account used by Auto-TLS provisioning. |
| `cm_ldap_enabled` | Boolean; `true` | Configures CM external LDAP authentication. Set false to keep database-only authentication. |
| `cm_ldap_auth_backend_order` | `DB_ONLY`, `LDAP_THEN_DB`, `DB_THEN_LDAP`, `LDAP_ONLY`, `EXTERNAL_ONLY_WITHOUT_DB_ADMINS` | Controls CM login fallback/order. `DB_THEN_LDAP` preserves local CM admin recovery. |
| `cm_ldap_update_bind_password` | Boolean; `false` | Set true only to rotate the existing LDAP bind password; CM redacts it on reads. |
| `cm_cms_update_reports_manager_password` | Boolean; `false` | Set true only to rotate the CMS Reports Manager database password. |
| `cm_cms_update_autotls_truststore_password` | Boolean; `false` | Set true only to rotate the CMS Auto-TLS truststore password. |

Auto-TLS provisioning uses password mode when secret
`cm_node_sudo_password` is provided; otherwise it uses SSH-key mode.

## 5. ECS and data services

| Variable | Accepted values/default | What it does |
|---|---|---|
| `ecs_deploy_enabled` | `auto`, `true`, `false` | `auto` deploys when ECS inventory groups contain hosts; `true` requires them; `false` skips ECS. |
| `ecs_cluster_name` | Name; `ECS-Cluster` | ECS cluster name created in CM. |
| `ecs_cluster_master_group` | Inventory group; `ecs-masters` | Hosts assigned ECS master/control-plane roles. |
| `ecs_cluster_worker_group` | Inventory group; `ecs-workers` | Hosts assigned ECS worker roles. |
| `ecs_data_services_deploy_enabled` | Boolean; `false` | Master gate for playbook 34 data-service deployment. |
| `ecs_deploy_cdw` | Boolean; `false` | Deploys Cloudera Data Warehouse when the master gate is enabled. |
| `ecs_deploy_cde` | Boolean; `false` | Deploys Cloudera Data Engineering when the master gate is enabled. |
| `ecs_deploy_cai` | Boolean; `false` | Deploys Cloudera AI when the master gate is enabled. |
| `ecs_deploy_cai_registry` | Boolean; `false` | Deploys Model Registry when the master gate is enabled. |
| `ecs_ldap_enabled` | Boolean; `false` | Enables ECS LDAP integration; requires working directory settings and credentials. |

## 6. Deployment portal and monitoring

| Variable | Accepted values/default | What it does |
|---|---|---|
| `deployment_owner` | String or empty | Display/metadata owner. Empty allows wrapper/Terraform metadata to supply it. |
| `deployment_name_prefix` | DNS-safe string or empty | Prefix used for deployment resources and labels. Empty allows the environment/workspace value to supply it. |
| `deployment_portal_enabled` | Boolean; `true` | Installs and refreshes the Caddy portal stack. |
| `deployment_portal_host_group` | `auto` or inventory group | `auto` prefers `ipaserver`, then `cldr-mngr`; an explicit group places the portal there. |
| `deployment_portal_access_profile` | `auto`, `cloud`, `private` | Chooses public versus private URL/address preference. `auto` derives it from controller reachability. |
| `deployment_portal_basic_auth_enabled` | Boolean; `true` | Protects `/downloads/*` and operator credential content. Disabling it removes downloadable SSH-key content. |
| `deployment_portal_expose_credentials` | Boolean; `true` | Shows the protected operator credential panel when authentication is enabled. |
| `deployment_portal_expose_ssh_keys` | Boolean; `true` | Publishes SSH key downloads only behind active portal authentication. |
| `caddy_vhost_enabled` | Boolean; `true` | Enables readable Caddy virtual-host URLs in addition to direct host/port URLs. |
| `caddy_vhost_public_base` | DNS suffix; `pvc.cloudera-labs.com` | Base suffix for embedded-IP public vhost names. Ensure DNS behavior matches the selected Caddy mode. |
| `monitoring_stack_enabled` | Boolean; `true` | Installs Grafana, Prometheus, exporters, and related portal links when the monitoring stage runs. |

## Example profiles

### FreeIPA, CDH, and monitoring

```yaml
identity_provider: freeipa
deployment_environment: aws
ipaserver_domain: lab.example.com
ecs_deploy_enabled: false
monitoring_stack_enabled: true
```

### Active Directory on existing hosts

```yaml
identity_provider: ad
deployment_environment: baremetal
ad_domain: corp.example.com
ad_kdc_host: dc01.corp.example.com
ad_dns_servers:
  - 10.20.0.10
  - 10.20.0.11
ad_join_user: svc-cloudera-join
ad_kdc_admin_user: svc-cloudera-kdc
ad_ldap_bind_dn: "CN=svc-cm-ldap,OU=Service Accounts,DC=corp,DC=example,DC=com"
ad_ldap_user_search_base: "OU=Users,DC=corp,DC=example,DC=com"
ad_ldap_group_search_base: "OU=Groups,DC=corp,DC=example,DC=com"
```

Provide the three passwords separately using Jenkins password parameters or
Vault; do not add them to this tracked example.
