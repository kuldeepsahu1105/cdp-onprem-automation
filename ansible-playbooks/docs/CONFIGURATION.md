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

## Operator editing checklist

Ansible does **not** use a project `.env` file for these settings. From the
repository root, edit the deployment YAML, not the derived defaults:

```bash
cd ansible-playbooks
vi config.yml
# Ansible-only hosts: copy once, then edit your operator-owned inventory.
cp inventory.example.ini inventory.ini
vi inventory.ini
```

Do not copy over an existing deployment inventory. For AWS/Terraform runs,
`inventory.ini` is generated: inspect it, but **never edit it**; fix Terraform
inputs/state and regenerate it instead. In `vi`, use `i` to edit, `Esc` then
`:wq` + Enter to save/quit, or `:q!` + Enter to discard unsaved changes.
Keep `group_vars/all.yml` as the defaults/derived-value reference; any
documented override below can be added to `config.yml` even if absent there.
Extra vars (including Jenkins fields) can override your saved choices.

Before deployment, verify/update every applicable row:

| Requirement | Actual parameters / what to check |
|---|---|
| Always: environment and access | `deployment_environment` (`aws` or `baremetal`, or verified `auto`), `ansible_control_reachability` (`auto`, `public`, `private`), `ansible_user`, `ansible_ssh_private_key_file`; optional `ansible_ssh_common_args` for a real bastion route. Use the target OS SSH account and a matching protected key, not the shipped `./id_rsa` assumption. |
| Always: inventory | `[cldr-mngr]`, `[base-masters]`, `[base-workers]`; each active host's `ansible_host` (controller-reachable), `private_ip` (cluster traffic), `cldr_hostname` (unique short name), optional `public_ip` (public links). Keep both `[ecs-masters]` and `[ecs-workers]` headers even when empty; do not populate `[deployment_portal_runtime]` manually. `[postgres]` (legacy `[db]`) is optional; omit its hosts to use the manager database. |
| FreeIPA only | `identity_provider: freeipa` (or verified `auto`), `[ipaserver]` host, `ipaserver_domain`, `dns_forwarders`; supply `ipaadmin_password` securely. Domain must match the intended DNS/Kerberos namespace; do not reuse the lab domain/password. |
| AD only | `identity_provider: ad`, `ad_domain`, `ad_kdc_host`, `ad_dns_servers`, `ad_join_user`, optional `ad_computer_ou`, `ad_kdc_admin_user`, `ad_ldap_bind_dn`, `ad_ldap_user_search_base`, `ad_ldap_group_search_base`; remove the FreeIPA host. Replace example DNs and supply AD secrets as described below. |
| Conditional DNS | `extra_dns_search_domains`, `extra_dns_nameservers`, `identity_dns_external_probe_host`, `dns_manage_networkmanager_resolv_conf`; verify forward/reverse resolution and approved DNS forwarding. Restricted networks may need an internal probe hostname or explicit `"off"`. |
| Always: product/artifact compatibility | `cm_version`, `cm_numeric_version`, `cdh_version`, `cdh_numeric_version`, `java_version`, `python_version`, `postgresql_version`, `postgres_jdbc_version`, `cm_repo_source`; ensure versions/build IDs exist for your OS and entitlement. On RHEL review `rhel_release_pin` (`auto` or the intended `major.minor`). Supply `cm_repo_username` and `cm_repo_password` securely. `cm_repo_source: internal` selects a mirror on the manager, not an arbitrary URL or an automatic offline deployment. |
| Conditional parcel/CSD choices | `cdh_parcel_os_suffix`, `cm_parcel_repo_urls_override`, `cm_parcel_repo_extra_urls`, `cm_csd_urls_override`, `cm_parcel_repo_include_ecs_parcel`, `cm_parcel_repo_include_cdv_parcel`, `cm_parcel_repo_include_cfm_parcel`, `csd_respect_service_toggles`; review `cdv_version`, `cfm_version`, `cfm_nifi_app_version` for those artifacts. Empty override lists retain generated URLs; full replacement lists must contain every required repo/CSD. |
| Base cluster | `cdh_basecluster_name`, `base_cluster_master_group`, `base_cluster_worker_group`, every boolean in `base_cluster_install_services`, `base_cluster_kafka_metadata_store`, `base_cluster_enable_kerberos`, `base_cluster_enable_autotls`; choose Kafka's metadata store before first start, and verify placement/sizing for enabled services. |
| Always: credentials/security | Replace lab/default values via protected extra vars: `cm_admin_user`, `cm_admin_pass`, `postgres_password`, `scm_db_password`, `common_password`, and enabled services' `base_cluster_hive_database_password`, `base_cluster_hue_database_password`, `base_cluster_ranger_database_password`, `base_cluster_ranger_admin_password`, `base_cluster_knox_database_password`, `base_cluster_knox_master_secret`. Review database names/users and `cm_cms_reports_manager_db_password` for consistency. This is not an exhaustive secret inventory: inspect the defaults for every enabled service. |
| TLS / LDAP | `autotls_enabled`, `use_freeipa_for_crt_mgmt`, `cm_srvr_sudo_user`, `cm_private_key_path`; conditional secret `cm_priv_key_passphrase` or `cm_node_sudo_password` for the chosen authentication mode. Verify `cm_ldap_enabled`, `cm_ldap_scheme`, `cm_ldap_port`, `cm_ldap_auth_backend_order`. Do not enable force/secret-update toggles unless deliberately rotating existing state. |
| ECS only | `ecs_deploy_enabled`, populated ECS groups, `ecs_cluster_master_group`, `ecs_cluster_worker_group`, `ecs_cluster_name`, `ecs_pvc_ds_version`, `ecs_app_domain`, `ecs_docker_data_path`, `ecs_lso_data_path`, `ecs_longhorn_data_path`, `ecs_longhorn_replication`; verify wildcard DNS/storage/sizing. Review `ecs_control_plane_database_mode` and `ecs_control_plane_vault_mode`; do not switch away from embedded defaults without the complete external-service configuration required by the selected ECS release. Replace `ecs_k8s_webui_secret_admin_token` securely; it is an internal installer/service token, not an end-user portal login. |
| Optional ECS services | `ecs_data_services_deploy_enabled`, `ecs_deploy_cdw`, `ecs_deploy_cde`, `ecs_deploy_cai`, `ecs_deploy_cai_registry`, `ecs_ldap_enabled`; leave off unless prerequisites and service-specific credentials are supplied. Verify `ecs_control_plane_url` (or its domain-derived URL) and protected `ecs_api_access_key_id`, `ecs_api_private_key` when supplying API credentials rather than automatic provisioning. |
| Optional portal / monitoring | `deployment_portal_enabled`, `deployment_portal_host_group`, `deployment_portal_postgres_host_group`, `deployment_portal_access_profile`, `caddy_vhost_enabled`, `caddy_vhost_public_base`, `deployment_portal_http_port`, `monitoring_stack_enabled`; review listener access/SGs. Verify `pgadmin_default_email` (valid TLD), protected `pgadmin_default_password`, `deployment_portal_basic_auth_password`, `monitoring_grafana_admin_password`. Keep authentication enabled; set `deployment_portal_expose_credentials` and `deployment_portal_expose_ssh_keys` false when publishing credentials/keys is not intended. |

### Secrets and generated files

Never paste real passwords into tracked config, example commands, Git, build
logs or shared terminal history. Use a secret manager/Jenkins masked fields,
or create an encrypted extra-vars file **outside the checkout**:

```bash
umask 077
EDITOR=vi ansible-vault create /secure/path/deployment-secrets.vault.yml
# Later edits (opens vi and re-encrypts on save):
EDITOR=vi ansible-vault edit /secure/path/deployment-secrets.vault.yml
```

Replace `/secure/path` with an existing private directory. The vault editor
contains YAML keys from the checklist, not shell `export` statements.
`<username>`, `<password>`, `replace-me`, `ChangeMe...`, `corp.example.com`,
sample service accounts, and template IP addresses are placeholders or lab
defaults, not usable production inputs. Do not assume `.gitignore` excludes
all local secret/config files.

`pvc_setup.sh` / the clone wrapper translate `CM_REPO_USERNAME` and
`CM_REPO_PASSWORD` (or `CM_INFO_FILE` with `login:` / `password:` lines) into
Ansible extra vars. **Direct `ansible-playbook` does not perform that
translation**: pass `cm_repo_username` / `cm_repo_password` in the Vault file.
Similarly `ANSIBLE_EXTRA_VARS` is a `pvc_setup.sh` input; for direct playbooks
use `-e @/secure/path/deployment-secrets.vault.yml --ask-vault-pass`.
Use `--private-key /secure/path/key` for direct Ansible/ad-hoc commands, or
set `ansible_ssh_private_key_file` explicitly; exporting `ANSIBLE_PRIVATE_KEY`
alone is a repository wrapper input, not Ansible's standard CLI setting.

Never edit generated `jenkins_override.yml`, remote portal/monitoring `.env`,
`docker-compose.yml`, Caddyfile, rendered repository files, or runtime facts.
Change `config.yml` / protected extra vars / Jenkins inputs and rerun the
owning phase. The remote `.env` files are template outputs, not operator
deployment inputs. License/key files are supplied artifacts, not files to
edit in `vi`.

### Pre-run checks in order

1. Complete the checklist and select the intended inventory/key/credential
   source. For AWS, first review the Terraform plan using the
   [AWS checklist](../../READme.adoc#operator-editing-checklist); inspect the
   inventory generated after provisioning.
2. From the repository root, run local static checks:
   `./jenkins/scripts/validate-ansible-yaml.sh` and
   `./jenkins/scripts/validate-ansible-contracts.sh` (Python 3 + PyYAML).
   These do not connect to hosts, but do not validate all deployment values.
3. With Ansible and required collections already available, from
   `ansible-playbooks/` run
   `ansible-playbook -i inventory.ini 11_identity_setup.yml --syntax-check`.
   Supply Vault extra vars if required. This parses the playbook, not a
   deployment; missing collections must be resolved before proceeding.
4. When ready to contact hosts, follow the
   [runbook validation/deployment sequence](RUNBOOK.md). Ansible `--check`
   is **not** a no-side-effect validator: tasks may explicitly run outside
   check mode, wrappers may install tools/collections, and `--diff` can expose
   secrets. Do not substitute a full `DRY_RUN=true` deployment for static checks.

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
| `rhel_release_pin` | `auto` (configured default) or `major.minor` | With `auto`, the first run detects and persists each host's current RHEL minor before any package operation; reruns reuse that persisted minor instead of adopting a newer release. Pins both DNF `$releasever` and subscription-manager when available; AWS RHUI uses `/etc/dnf/vars/releasever`. Any mismatch between the running OS and the persisted or explicit pin fails rather than attempting an unsafe downgrade. |
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
For Ansible runs, precedence is `group_vars/all.yml`, then `config.yml`, then
the Jenkins `ANSIBLE_GROUP_VARS_YAML` extra-vars file. The `cm_version` field in
`.tfvars.yaml` is a Terraform-wrapper reference and does not override these
Ansible values. The Ansible deployment banner prints both values when they differ.

| Variable | Default | What it controls |
|---|---|---|
| `java_version` | `"17"` | JDK installed on managed hosts. |
| `python_version` | `"3.11"` | Preferred target Python package version; Ansible still uses each host's configured `ansible_python_interpreter`. |
| `postgresql_version` | `18` | PostgreSQL server/client target version. |
| `postgres_jdbc_version` | `"42.7.10"` | JDBC driver downloaded for CM services. |
| `cm_version` | `"7.13.2.6"` | Cloudera Manager package/repository version. |
| `cm_numeric_version` | `"713200006"` | Numeric CM build path used by archive URLs; update with `cm_version`. |
| `cdh_version` | `"7.3.2.0"` | Runtime parcel version. |
| `cdh_numeric_version` | `"77083870"` | CDH parcel build identifier; update with `cdh_version`. |
| `cdv_version` | `"8.0.7"` | Data Visualization CSD/parcel release. |
| `cfm_version` | `"2.1.7.3004"` | Flow Management CSD/parcel release. |
| `cfm_nifi_app_version` | `"1.28.1"` | NiFi application segment used in CSD filenames. |
| `ecs_pvc_ds_version` | `"1.5.5-h3300"` | ECS/CDP Private Cloud Data Services repository tag. |
| `cm_repo_source` | `public` or `internal` | `public` installs from the Cloudera archive; `internal` builds/uses the CM-host mirror. |
| `cm_parcel_repo_urls_override` | `[]` or list of directory URLs | Non-empty **replaces the entire** CM parcel repository list. Include every CDH/CDV/CFM/ECS repository required. |
| `cm_csd_urls_override` | `[]` or list of `.jar` URLs | Non-empty replaces generated CSD downloads. Include every required CSD JAR. |
| `cm_parcel_repo_extra_urls` | `[]` or list of directory URLs | Appends repositories without replacing generated URLs. Use this for optional/custom parcels. |
| `csd_respect_service_toggles` | Boolean; `false` | When false, stages DataViz, NiFi, and NiFi Registry CSD JARs even while those optional services are disabled. |
| `cm_parcel_repo_include_ecs_parcel` | Boolean; `true` | Adds pinned ECS and required ECS `latest` repository candidates. |
| `cm_parcel_repo_include_cdv_parcel` | Boolean; `true` | Adds the pinned Data Visualization parcel repository. |
| `cm_parcel_repo_include_cfm_parcel` | Boolean; `true` | Adds the pinned Flow Management parcel repository used by NiFi services. |

Repository URLs must be directories for CM parcel configuration; CSD override
entries must be complete `.jar` URLs. See
[REFERENCE.md](REFERENCE.md#cmcdh-repository-source) for generated URL shapes.

## 3. Base cluster

| Variable | Accepted values/default | What it does |
|---|---|---|
| `cdh_basecluster_name` | Name; `CDP-base-cluster` | Cluster name created in CM. The unchanged default safely adopts an existing legacy `CDH-Cluster` or the single CM cluster that already owns every configured base host. |
| `base_cluster_adopt_by_master_host` | Boolean; `true` | When the unchanged default name is absent, adopt the single existing cluster containing the configured base master only if it contains all expected base hosts; ambiguous or partial matches fail safely. |
| `base_cluster_adopt_existing_ozone_ha` | Boolean; `true` | Preserve an adopted populated cluster's initialized Ozone service ID and recover an existing odd-sized SCM HA quorum (at least three roles) without adding/removing SCM roles; new clusters retain the single-SCM topology. |
| `base_cluster_enable_kerberos` | Boolean; `true` | Configures newly created base clusters for Kerberos before First Run; safely converges existing unsecure clusters and verifies HDFS authentication. |
| `base_cluster_restart_cms_after_start` | Boolean; `true` | Allows a Cloudera Management Service restart after First Run or a cluster Auto-TLS/Kerberos transition. Healthy reruns and service recovery do not restart CMS. |
| `base_cluster_kafka_metadata_store` | `Zookeeper` or `KRaft`; `Zookeeper` | Kafka metadata backend selected before Kafka's first successful start. |
| `base_cluster_master_group` | Inventory group; `base-masters` | Hosts eligible for master roles. |
| `base_cluster_worker_group` | Inventory group; `base-workers` | Hosts eligible for worker roles and parcel OS detection. |
| `base_cluster_module_async_timeout` | Seconds; `7500` | Outer bound for cluster creation, parcel activation, and First Run. |
| `base_cluster_module_poll_interval` | Seconds; `15` | Jenkins progress-update interval while the cluster module waits on CM. |
| `base_cluster_knox_readiness_recovery_retries` | Integer; `30` | Maximum health polls when Knox is the sole First Run readiness failure. |
| `base_cluster_knox_readiness_recovery_delay` | Seconds; `10` | Delay between bounded Knox recovery health polls. |
| `base_cluster_hue_database_name` | Database name; `hue` | PostgreSQL database used by Hue instead of its non-production SQLite fallback. |
| `base_cluster_hue_database_user` | Database user; `hue` | PostgreSQL login used by Hue. |
| `base_cluster_hue_database_password` | Secret; `hue` | PostgreSQL password used by Hue; override through a vault or `ANSIBLE_GROUP_VARS_YAML`. |
| `base_cluster_repair_hive_canary_catalogs` | Boolean; `true` | Before starting an existing cluster, makes Hive's `DBS_FK1` constraint deferred so transactional catalog deletion works, then removes only stale CM health-canary catalogs after refusing cleanup when they contain tables or functions. |

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
| `spark3` | `true` | Installs Spark 3 on YARN with a History Server and client gateways. |
| `hive` | `true` | Installs Hive services and metadata integration. |
| `hive_on_tez` | `true` | Configures Hive to use Tez; requires Hive and Tez. |
| `hbase` | `true` | Installs HBase; requires ZooKeeper and HDFS. |
| `hue` | `true` | Installs the Hue web application. |
| `iceberg` | `true` | Validates the Hive, Impala, and Spark 3 services that provide Iceberg support in CDP 7.3.x; Iceberg is not a standalone CM service. |
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
| `cm_autotls_https_startup_timeout` | Integer seconds; `600` | Maximum wait for CM HTTPS port `7183` after `generateCmca` and the scm-server restart. |
| `use_freeipa_for_crt_mgmt` | Boolean/expression; derived from identity | When true, requires and trusts `/etc/ipa/ca.crt` during Auto-TLS. Set false for CM-generated CA without FreeIPA trust. |
| `cm_private_key_path` | Path or empty | Auto-TLS SSH-key provisioning key. Empty auto-discovers `sshkey.pem` or the Ansible SSH key. |
| `cm_priv_key_passphrase` | Secret string or empty | Passphrase for `cm_private_key_path`; leave empty for an unencrypted key. Prefer Vault/secret input. |
| `cm_srvr_sudo_user` | User; `root` | Remote sudo-capable account used by Auto-TLS provisioning. |
| `cm_ldap_enabled` | Boolean; `true` | Configures CM external LDAP authentication. Set false to keep database-only authentication. |
| `cm_ldap_auth_backend_order` | `DB_ONLY`, `LDAP_THEN_DB`, `DB_THEN_LDAP`, `LDAP_ONLY`, `EXTERNAL_ONLY_WITHOUT_DB_ADMINS` | Controls CM login fallback/order. `DB_THEN_LDAP` preserves local CM admin recovery. |
| `cm_ldap_update_bind_password` | Boolean; `false` | Set true only to rotate the existing LDAP bind DN/password pair. CM may redact both credential values on reads, so ordinary reruns verify their presence rather than comparing an unavailable value. |
| `cm_krb_update_libdefaults_safety_valve` | Boolean; `false` | Set true only to intentionally rewrite `KRB_LIBDEFAULTS_SAFETY_VALVE`. CM returns this setting as `REDACTED`, so ordinary reruns verify presence and do not treat the redaction token as drift. |
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
| `monitoring_node_exporter_port` | TCP port; `19100` | Host-level node_exporter listener and Prometheus target port. Port 19100 avoids conflicts with Kubernetes applications that reserve host port 9100 for a DaemonSet. Re-run **MONITORING** after changing it. |
| `monitoring_process_exporter_port` | TCP port; `19256` | Host-level process_exporter listener and Prometheus target port. The nonstandard port avoids workloads that deploy their own process exporter on conventional host port 9256. |
| `monitoring_cadvisor_cluster_port` | TCP port; `19180` | Host-level cAdvisor Docker publish on ECS/cluster nodes (`cadvisor_host` job). Avoids YARN/UI ports such as 8088. Re-run **MONITORING** after changing. |
| `monitoring_cadvisor_host_groups` | inventory groups | Hosts that receive standalone `cldr-host-cadvisor` and a `cadvisor_host` scrape target. Defaults to ECS masters/workers; the ops host is already covered by the monitoring Compose cAdvisor. |

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
