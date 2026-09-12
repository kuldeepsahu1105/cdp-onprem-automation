# Reference — Detailed Documentation

Complete reference for playbooks, variables, inventory, identity detection, DNS, and cleanup.

---

## Configuration (`group_vars/all.yml`)

### Core versions

| Variable | Default | Description |
|---|---|---|
| `java_version` | `17` | OpenJDK version |
| `python_version` | `3.11` | Python version (packages and module enablement) |
| `postgresql_version` | `18` | PostgreSQL version |
| `cm_version` | `7.13.2.10000` | Cloudera Manager version |
| `cdh_version` | `7.3.2.10000` | CDH parcel version |

### Cluster names

| Variable | Default |
|---|---|
| `cdh_basecluster_name` | `CDH-Cluster` |
| `base_cluster_install_services` | see `all.yml` | Per-service booleans for `31_setup_base_cluster.yml` (Knox default `true`; NiFi, DataViz, Phoenix, Solr default `false`) |
| `cm_admin_bootstrap_pass` | `admin` | Factory CM password; when `cm_admin_pass` differs, `set_cm_api_url` resets admin via API |
| `base_cluster_yarn_*` | `4096` / `4` | YARN RM/NM memory and vcore limits in cluster spec template |
| `ecs_cluster_name` | `ECS-Cluster` |
| `ecs_deploy_enabled` | `auto` | `auto`, `true`, or `false` — deploy ECS when ecs inventory groups exist |
| `ecs_pvc_ds_version` | `1.5.5-h3300` | CDS repo tag (`1.5.5-h3300` = SP3 CHF3; older: `1.5.5-h2000` SP2, `1.5.5-h2100` SP2 CHF1) |
| `ecs_parcel_version` | `""` | Optional override; auto-discovered from CM after parcel repo refresh |
| `ecs_app_domain` | `apps.<domain>` | Application domain for ECS services |

### CM/CDH repository source

| Variable | Default | Description |
|---|---|---|
| `cm_repo_source` | `public` | `public` = archive.cloudera.com/p/ direct; `internal` = mirror on cldr-mngr |
| `cm_repo_public_base_url` | `https://archive.cloudera.com/p` | Public archive base URL |
| `cm_repo_mirror_host` | cldr-mngr IP | Internal mirror HTTP host |
| `parcel_repo` | computed | Public or internal parcel URL based on `cm_repo_source` |
| `cdh_parcel_os_suffix` | `auto` | Parcel filename suffix: `auto`, `el8`, `el9`, `jammy`, `noble`, `sles15`, `el8.aarch64le` |
| `cdh_parcel_target_group` | `base-workers` | Inventory group used to auto-detect worker OS for parcel suffix |
| `cdh_parcel_os_suffix_fallback` | `el8` | Fallback when auto-detect cannot read worker facts |
| `target_cpu_architecture` | `auto` | `auto`, `x86_64`, or `arm64` — set by wrapper when `CPU_ARCHITECTURE=arm64` |
| `ecs_deploy_on_arm64` | `false` | Allow ECS on ARM64/Graviton (experimental) |
| `cdh_parcel_arm64_suffix` | `.aarch64le` | Appended to parcel suffix on ARM64 workers when `auto` |
| `scm_csds` | `[]` | Explicit CSD JAR URLs (overrides auto-built list) |
| `scm_csds_redhat` | `[]` | Optional explicit RHEL CSD URL list (overrides auto-build) |
| `cdv_version` | `8.0.7` | Cloudera Data Visualization (CDV) CSD path version, e.g. `8.1.5` |
| `cdv_dataviz_csd_jar` | `DATAVIZ-{{ cdv_version }}-…` | DATAVIZ CSD jar basename under `cdv/<version>/<redhat8\|9>/yum/` |
| `cfm_version` | `2.1.7.3004` | Cloudera Flow Management (NiFi) CSD path version |
| `cfm_nifi_app_version` | `1.28.1` | NiFi app version segment in `NIFI-*.jar` / `NIFIREGISTRY-*.jar` |
| `cfm_nifi_csd_jar` / `cfm_nifi_registry_csd_jar` | computed | Jar basenames under `cfm2/<cfm_version>/…/parcel/` |
| `csd_redhat_repo` | `auto` | `redhat8`, `redhat9`, or `auto` from CM host OS |
| `csd_build_urls_enabled` | `true` | Build CSD URLs from version vars on RHEL when lists above are empty |
| `csd_respect_service_toggles` | `true` | Only include CSDs for enabled `base_cluster_install_services` keys |
| `cm_repo_username` | — | Required (archive credentials) |
| `cm_repo_password` | — | Required (archive credentials) |

**Spark parcel:** For CDH `>= 7.3.1`, Spark is bundled in the CDH parcel — a separate SPARK3 download is skipped automatically (`cdh_spark_bundled_min_version`). Set `spark_version` only for older CDH releases that need a standalone Spark parcel.

```yaml
# Public (default) — no local download
cm_repo_source: public
cm_repo_username: "your-cloudera-account"
cm_repo_password: "your-password"

# Internal mirror — CM + CDH parcels served from cldr-mngr web server
cm_repo_source: internal
```

**Internal mirror by OS:**

| cldr-mngr OS | Mirror format | What is downloaded |
|---|---|---|
| RHEL 8/9 | yum/RPM + `createrepo` | CM RPMs, CDH parcel (`-el8`/`-el9`) |
| Ubuntu 22.04/24.04 | apt | CM `.deb` packages + `Packages` index, CDH parcel |

**CDH parcel suffixes in archive** (CDH 7.3.2 example):

| Suffix | Target OS |
|---|---|
| `el8` | RHEL / Rocky / Alma 8 (x86_64) |
| `el9` | RHEL / Rocky / Alma 9 (x86_64) |
| `el8.aarch64le` / `el9.aarch64le` | RHEL on ARM64 |
| `jammy` | Ubuntu 22.04 workers |
| `noble` | Ubuntu 24.04 workers |
| `sles15` | SLES 15 |

With `cdh_parcel_os_suffix: auto` (default), the suffix is derived from the first host in `cdh_parcel_target_group` (`base-workers`). Override explicitly when workers are mixed or facts are not gathered yet.

| Playbook | Mode | Description |
|---|---|---|
| `20_setup_cm_repos.yml` | both | Router: 16 (internal web) + 17 |
| `21_setup_internal_repo.yml` | internal | Web server on cldr-mngr only |
| `22_download_repos.yml` | both | Mirror (internal) or configure public repo on all hosts |

### OS-specific settings

Package names and paths are in the `os_vars` map:

- `os_vars.RedHat` — RHEL/Rocky/Alma
- `os_vars.Debian` — Ubuntu (Ansible `Debian` OS family)

| `cm_repo_dir` | `/etc/yum.repos.d` (RHEL) or `/etc/apt/sources.list.d` (Ubuntu) | CM repo drop-in directory |
| `cm_repo_file` | `cloudera-manager.repo` or `cloudera-manager.list` | CM repo file name per OS |

On Ubuntu, public mode downloads the official `cloudera-manager.list` from `archive.cloudera.com/p/cm7/<version>/ubuntu2404/apt/` (or `ubuntu2204`, etc.) and imports `archive.key` — matching the Cloudera installation guide.

Access at runtime: `{{ os_vars[ansible_os_family].<key> }}` or `{{ os.<key> }}` after `set_os_facts`.

**PostgreSQL paths:** RHEL stores config in the data directory (`postgres_data_dir`). Ubuntu uses separate paths — config in `postgres_config_dir` (`/etc/postgresql/<version>/main`), data in `postgres_data_dir` (`/var/lib/postgresql/<version>/main`). Playbook `23_setup_postgres.yml` deploys templates to `postgres_config_dir`.

---

## Identity provider detection

| Variable | Default | Description |
|---|---|---|
| `identity_provider` | `auto` | `auto`, `freeipa`, or `ad` |
| `ipa_server_in_inventory` | computed | `true` when `[ipaserver]` has hosts |
| `identity_provider_effective` | computed | Resolved provider used by playbooks |
| `identity_client_hosts` | computed | `all:!ipaserver` or `all` when no ipaserver |

### Auto-detection rules

| Condition | Effective provider | Flow |
|---|---|---|
| `[ipaserver]` has hosts | `freeipa` | Full: 10→15 |
| No ipaserver + `ad_kdc_host` set | `ad` | Dependent: 11, 14, 23, 25 |
| `identity_provider: freeipa` | `freeipa` | Forced |
| `identity_provider: ad` | `ad` | Forced |

### FreeIPA variables

| Variable | Description |
|---|---|
| `ipaserver_domain` | DNS domain |
| `ipaserver_realm` | Kerberos realm (uppercase domain) |
| `ipaadmin_principal` | IPA admin user |
| `ipaadmin_password` | IPA admin password |
| `ipa_kdc_host` | `ipaserver.<domain>` |

### Active Directory variables

| Variable | Description |
|---|---|
| `ad_domain` | AD DNS domain |
| `ad_kdc_host` | AD DC IP or hostname |
| `ad_dns_servers` | List of DNS servers (usually DC IP) |
| `ad_join_user` | Account for `realm join` |
| `ad_join_password` | Password for join account |
| `ad_ldap_bind_dn` | CM LDAP bind DN |
| `ad_ldap_user_search_base` | LDAP user search base |
| `ad_ldap_group_search_base` | LDAP group search base |

---

## DNS configuration

| Variable | Default | Description |
|---|---|---|
| `deployment_environment` | `auto` | `auto`, `aws`, or `baremetal` |
| `aws_region` | env `AWS_REGION` | AWS region for `region.compute.internal` |
| `aws_vpc_dns_resolver` | auto | VPC DNS (`x.y.0.2` from private IP) |
| `extra_dns_search_domains` | `[]` | Additional search domains |
| `extra_dns_nameservers` | `[]` | Additional nameservers |

### Per OS

| OS | Method |
|---|---|
| Ubuntu (netplan) | `/etc/netplan/99-cloudera-dns.yaml` + `netplan apply` |
| RHEL | `/etc/resolv.conf` via template |

### Per environment

| Environment | Search domains | Extra nameservers |
|---|---|---|
| AWS | cluster domain + `{region}.compute.internal` | VPC resolver `x.y.0.2` |
| Bare metal | cluster domain only | none (IPA/AD DNS only) |

---

## Inventory groups

| Group | Role |
|---|---|
| `ipaserver` | FreeIPA server (omit for AD-only) |
| `cldr-mngr` | Cloudera Manager + PostgreSQL + CMS |
| `base-masters` | CDP base cluster master |
| `base-workers` | CDP base cluster workers |
| `ecs-masters` | ECS master |
| `ecs-workers` | ECS workers |

Each host should define: `ansible_host`, `private_ip`, `cldr_hostname`.

---

## Playbook reference

Run: `ansible-playbook -i inventory.ini <playbook>.yml`

For Jenkins / wrapper execution order and why some numbers appear twice (10, 14, 16), see [RUN_ORDER.md](RUN_ORDER.md).

### Phase 1 — Infrastructure & prerequisites

| Playbook | Description |
|---|---|
| `00_setup_ssh_preqs.yml` | SSH prerequisites |
| `00_ensure_collections.yml` | Galaxy install from `requirements.yml` (imported by every playbook; same logic as `pvc_setup.sh`) |
| `01_install_collection.yml` | Imports `00_ensure_collections`; full system update on targets |
| `02_set_hostname.yml` | Set FQDN hostnames |
| `03_create_etc_hosts.yml` | Populate `/etc/hosts` |
| `04_setup_autossh.yml` | Passwordless SSH |
| `05_disable_selinux.yml` | SELinux permissive (RHEL) |
| `06_prereq_setup.yml` | Base packages, Java, Python 3.11 |
| `07_prereq_setup_002.yml` | sysctl, ulimit, THP, chrony |
| `08_prereq_setup_003.yml` | PostgreSQL client + PGDG repo |
| `09_verify_os_prereqs.yml` | Verify OS prerequisites |

### Phase 2 — Identity & DNS

| Playbook | Description |
|---|---|
| `00_detect_identity.yml` | Detect FreeIPA vs AD |
| `11_identity_setup.yml` | Phase 2 router (all of 10–15) |
| `12_setup_freeipa_server.yml` | FreeIPA server (skipped for AD) |
| `13_update_resolv_conf.yml` | DNS (netplan or resolv.conf) |
| `14_setup_dns_records.yml` | FreeIPA DNS records (skipped for AD) |
| `15_update_syscfg_network.yml` | `/etc/sysconfig/network` (RHEL) |
| `16_setup_identity_client.yml` | FreeIPA client or AD realm join |
| `18_setup_ad_client.yml` | AD realm join only |
| `17_setup_freeipa_client.yml` | FreeIPA client only |
| `19_setup_wildcard.yml` | `*.apps` wildcard DNS (FreeIPA only) |

### Phase 3 — Cloudera Manager

| Playbook | Description |
|---|---|
| `20_setup_cm_repos.yml` | **Repo router** — internal web + mirror or public archive config |
| `21_setup_internal_repo.yml` | Internal HTTP repo web server (skipped when `cm_repo_source=public`) |
| `22_download_repos.yml` | Mirror from archive (internal) or configure public `archive.cloudera.com/p/` repos |
| `23_setup_postgres.yml` | PostgreSQL for CM |
| `24_start_cm.yml` | Install/start CM server + agents |
| `25_verify_cm.yml` | Verify CM is running |
| `26_setup_cm_license.yml` | Upload license or trial |
| `27_setup_cm_autotls.yml` | Enable Auto-TLS |
| `28_setup_cm_krbs.yml` | Kerberos (FreeIPA or AD KDC) |
| `30_setup_cm_ldap.yml` | LDAP auth (FreeIPA or AD) |

### Phase 4 — CMS & base cluster

CMS (Management Service) and CDP base cluster are **separate**:

| Playbook | Component | Deploys |
|---|---|---|
| `29_setup_cm_cms.yml` | CMS | Service Monitor, Host Monitor, Event Server, etc. |
| `31_setup_base_cluster.yml` | Base cluster | HDFS, Ozone, YARN, Hue, Tez, Hive, Hive on Tez, HBase, Core Settings, Iceberg, Replication Manager, Impala, Kafka, ZooKeeper, Atlas, Ranger; optional NiFi, NiFi Registry, DataViz, Phoenix, Knox, Solr (`base_cluster_install_services`) |
| `33_setup_ecs_cluster.yml` | ECS cluster | Cloudera Data Services (DOCKER + ECS), embedded control plane |
| `10_setup_deployment_portal.yml` | Ops portal bootstrap | Caddy, pgAdmin, optional monitoring on ops host (`auto` → ipaserver else cldr-mngr); run early in phase 1 |
| `32_setup_monitoring_stack.yml` | Monitoring only | Add monitoring after 28 (requires portal network) |
| `34_setup_ecs_data_services.yml` | ECS data services | CDW/CDE/CAI via control plane API (credentials + `ecs_data_services_install`; stubs — extend API tasks) |

**ECS API keys (automation):** IAM `createMachineUserAccessKey` requires a **signed** request. Password-only console login is not enough. After ECS is up, either set `ecs_api_access_key_id` / `ecs_api_private_key`, or set a **one-time** bootstrap admin key (`ecs_iam_bootstrap_*` or Jenkins `ECS_IAM_BOOTSTRAP_*` credentials) and enable `ecs_auto_provision_api_access_key` (default `true`) to create machine user `ecs_automation_machine_user` via CDP CLI; keys are cached at `ecs_api_credentials_cache_path`.
| `35_refresh_deployment_portal.yml` | Portal refresh | Re-render index/Caddy after CM, base, ECS, or DS changes (no full reinstall) |

Requires base cluster for `control_plane.datalake_cluster_name`. Uses `ecs-masters` / `ecs-workers` inventory groups. Skipped when `ecs_deploy_enabled: auto` and ECS groups are empty.

### Deployment portal & monitoring (`group_vars/all.yml`)

| Variable | Default | Description |
|---|---|---|
| `deployment_portal_enabled` | `true` | Run `10_setup_deployment_portal.yml` |
| `deployment_portal_host_group` | `auto` | `auto`, `ipaserver`, or `cldr-mngr` — where Caddy/pgAdmin/Grafana run |
| `deployment_portal_postgres_host_group` | `cldr-mngr` | CM PostgreSQL host for pgAdmin |
| `deployment_portal_http_port` | `81` | Caddy index + Grafana/Prometheus/Alertmanager paths |
| `deployment_portal_pgadmin_host_port` | `5050` | pgAdmin UI on ops host |
| `monitoring_grafana_host_port` | `3000` | Grafana UI on ops host (docker `HOST:3000`) |
| `monitoring_prometheus_host_port` | `9090` | Prometheus UI on ops host |
| `monitoring_alertmanager_host_port` | `9093` | Alertmanager UI on ops host |
| `monitoring_cadvisor_host_port` | `8089` | cAdvisor metrics UI on ops host |
| `pgadmin_default_email` | `admin@{{ caddy_vhost_public_base }}` | pgAdmin 8 login email (`PGADMIN_DEFAULT_EMAIL`); must not use `.local` cluster domains |
| `deployment_portal_access_profile` | `auto` | `auto`, `cloud` (public + VPC URLs), or `private` (bare metal / no public IP) |
| `deployment_portal_prefer_fqdn_urls` | `true` | In `private` profile, use ops FQDN in portal links instead of raw management IP |
| `deployment_portal_use_private_network_only` | `false` | Force `private` profile even when inventory has distinct public/private IPs |
| `monitoring_stack_enabled` | `true` | Prometheus + Grafana + Alertmanager + cAdvisor with playbook 28; Jenkins `MONITORING_STACK_ENABLED` checkbox sets this override |
| `deployment_portal_extra_links` | `[]` | Add `{name, url}` entries to the index page |
| `monitoring_prometheus_extra_targets` | `[]` | Extra Prometheus scrape jobs |
| `caddy_vhost_enabled` | `true` | Host-based Caddy URLs (nip.io-style) |
| `caddy_vhost_public_base` | `pvc.cloudera-labs.com` | Base domain for `svc.<ip-dashed>.<base>` |
| `caddy_vhost_dns_mode` | `embedded_ip` | `embedded_ip`, `classic_nipio`, or `flat` |
| `autotls_enabled` | `false` | CM listens on `:7183` (direct; not via Caddy) |

---

## Cleanup (`99_cleanup.yml`)

Requires:

```bash
-e cleanup_enabled=true -e cleanup_confirm=true
```

### Toggles

| Toggle | Purpose |
|---|---|
| `cleanup_stop_cms` | Stop CMS via API |
| `cleanup_delete_cms` | Delete CMS via API |
| `cleanup_delete_base_cluster` | Delete base cluster + node cleanup |
| `cleanup_delete_ecs_cluster` | Delete ECS cluster + node cleanup |
| `cleanup_remove_cm` | Uninstall CM server |
| `cleanup_remove_cm_agents` | Remove CM agents |
| `cleanup_stop_postgres` | Stop PostgreSQL |
| `cleanup_remove_postgres_data` | Remove PG data (optional backup) |
| `cleanup_backup_postgres_data` | `true` = mv to backup dir |
| `cleanup_remove_postgres_packages` | Uninstall PostgreSQL packages |
| `cleanup_e2e` | Full teardown (service users, deep dirs) |
| `cleanup_reset_iptables` | Reset iptables (ECS nodes) |
| `cleanup_reboot_hosts` | Reboot after cleanup |

---

## Wrapper scripts

| Script | Location | Purpose |
|---|---|---|
| `clone_and_run_terraform.sh` | repo root | Terraform + inventory generation |
| `clone_and_run_pvc_automation.sh` | repo root | Clone repo, run `pvc_setup.sh` |
| `pvc_setup.sh` | `ansible-playbooks/` | Phased playbook runner (`DEPLOY_PHASE`) |
| `scripts/lib/ansible_env.sh` | repo root | Control mode, SSH key, license, CM creds resolution |
| `scripts/lib/portable.sh` | repo root | macOS/Linux portable helpers |

### `pvc_setup.sh` phases

| `DEPLOY_PHASE` | Alias | Playbooks |
|---|---|---|
| `1` | `prereq` | `00`–`09` |
| `2` | `identity` | `00_detect_identity`, `11_identity_setup` |
| `3` | `cm` | `20`–`26` |
| `4` | `cluster` | `22`–`27` (ECS skipped if no ecs inventory) |
| `5` | `ecs` | `33_setup_ecs_cluster.yml` |
| `all` | — | Full flow |

License file is required for phases `3`, `4`, and `all` only.

### Environment variables

| Variable | Purpose |
|---|---|
| `DEPLOY_PHASE` | `1`, `2`, `3`, `4`, or `all` (default `1`) |
| `CONTROL_MODE` | `remote` (default), `local`, or `auto` — whether Ansible runs from a cluster node |
| `ANSIBLE_PRIVATE_KEY` | SSH private key path (skips interactive prompt) |
| `LICENSE_FILE` | Cloudera license file (phases 3/4/all) |
| `CM_INFO_FILE` | `*info.txt` with archive `login:` / `password:` |
| `CM_REPO_USERNAME` / `CM_REPO_PASSWORD` | Archive credentials (alternative to `CM_INFO_FILE`) |
| `ANSIBLE_LIMIT` | Passed through to `ansible-playbook --limit` |

When multiple `*.pem`, `*license*`, or `*info.txt` files exist in `ansible-playbooks/`, `ansible_env.sh` prompts interactively. Non-interactive runs must set the env vars above.

### macOS notes

- Scripts require **bash**
- Homebrew installs Terraform, AWS CLI, `jq` when missing
- Use `cp` without GNU `--` separator (handled in portable helpers)

---

## Ansible collections (`requirements.yml`)

| Collection | Purpose |
|---|---|
| `community.general` | General modules |
| `community.postgresql` | PostgreSQL modules (Ubuntu) |
| `ansible.posix` | POSIX helpers |
| `community.crypto` | TLS/crypto |
| `freeipa.ansible_freeipa` | FreeIPA server/client |
| `cloudera.cluster` (devel) | CM/CDP API modules |

Install: `ansible-galaxy collection install -r requirements.yml`

## Common task modules

| Path | Purpose |
|---|---|
| `common_tasks/set_os_facts.yml` | Load `os_vars` map per OS family |
| `common_tasks/detect_identity_provider.yml` | FreeIPA vs AD detection |
| `common_tasks/set_dns_facts.yml` | AWS/bare metal DNS facts |
| `common_tasks/configure_resolv_conf.yml` | netplan or resolv.conf |
| `common_tasks/configure_cm_repo.yml` | Public or internal CM repo setup |
| `common_tasks/prepare_debian_cm_install.yml` | Ubuntu apt prep (needrestart, etc.) |
| `common_tasks/install_cm_packages.yml` | OS-aware CM server/agent package install |
| `common_tasks/configure_cm_agent.yml` | Set `server_host` in agent `config.ini` to cldr-mngr FQDN |
| `common_tasks/set_cm_mirror_facts.yml` | Internal mirror URL facts |
| `common_tasks/mirror_internal_cm_rhel.yml` | RPM mirror + createrepo |
| `common_tasks/mirror_internal_cm_apt.yml` | apt `.deb` mirror + Packages index |
| `common_tasks/install_postgresql_repo.yml` | PGDG repo per OS |
| `common_tasks/init_postgresql.yml` | PostgreSQL init |
| `common_tasks/restart_postgresql.yml` | OS-aware PostgreSQL restart |
| `common_tasks/disable_firewall.yml` | firewalld (RHEL) or ufw skip |
| `common_tasks/join_ad_realm.yml` | AD `realm join` |
| `common_tasks/join_freeipa_client.yml` | IPA client enrollment |
| `common_tasks/set_cm_api_url.yml` | CM API URL + Auto-TLS detection |
| `ansible_control_reachability` | `auto` | `auto`, `public` (Jenkins / no VPC route), or `private` (bare metal / VPN / `CONTROL_MODE=local`) |
| `cm_api_prefer_private_ip` | `true` | Legacy: prefer `private_ip` for CM API when profile is not `public` |
| `cm_api_connect_host` | `""` | Force CM API target (Jenkins may set `cldr-mngr` `ansible_host` / public IP) |
| `ansible_controller_outside_vpc` | `false` | Legacy mirror of `public` profile — do not use RFC1918 `private_ip` from controller |
| `cm_api_delegate_probes_to_manager` | `true` | In-VPC localhost plays: delegate CM API discovery to `cldr-mngr`. Skipped when control reachability is `public` (Jenkins probes `ansible_host` from the controller) |
| `cm_api_private_reachability_timeout` | `5` | Seconds to test VPC `private_ip` from controller before using public IP |
| `cm_external_url` | `""` | Override CM Caddy public URL; sets CM API `frontend_url` when non-empty |
| `cm_apply_caddy_frontend_url` | `false` | Deprecated — CM is not fronted by Caddy |
| `cm_config_api_via_caddy_proxy` | `false` | Deprecated — CM API probes use direct `:7180`/`:7183` |
| `cm_frontend_url_effective` | (fact) | Optional `cm_external_url` override only |
| `ecs_control_plane_url_effective` | (fact) | `ecs_control_plane_url` or `https://console.<ecs_app_domain>` |
| `deployment_portal_url_verify_skip_vpc` | `false` | Skip VPC-only portal URL hard-fail during verify (Jenkins sets `true`) |
| `deployment_external_url_verify` | `warn` | Tier B: GET external service URLs from controller when reachability is `public` — `warn`, `fail`, or `skip` |
| `deployment_portal_external_url_verify` | `warn` | Legacy Tier B default for portal when `deployment_external_url_verify` is unset |
| `deployment_service_external_url_verify` | — | Optional map of per-service Tier B modes (`cm`, `portal`, `grafana`, …) |
| `deployment_portal_verify_tier_b_enabled` | `false` | When `deployment_portal_enabled` is false, run Tier B from `25_verify_cm` (default: use `10`/`35` localhost play) |
| `common_tasks/install_cloudera_collection.yml` | Galaxy collection install |
| `common_tasks/cleanup/` | Modular cleanup tasks |

**Cross-playbook variable contracts** (portal verify chain, CM API facts, import order): see [`VARIABLE_CONTRACTS.md`](VARIABLE_CONTRACTS.md).
