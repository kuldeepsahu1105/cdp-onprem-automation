# Reference — Detailed Documentation

Complete reference for playbooks, variables, inventory, identity detection, DNS, and cleanup.

---

## Cloudera Labs CM stack alignment

Reference playbooks in [cloudera-labs/cloudera.cluster](https://github.com/cloudera-labs/cloudera.cluster) (tags `cm_autotls`, `cm_service`, `external_auth`, `cm_kerberos`) assume: Auto-TLS on the CM host → CMS with Reports Manager on the `postgresql` inventory group → LDAP via `cm_config` → Kerberos via `cm_kerberos`, often with a **reverse proxy** on the ops host for CM `:7183`.

This repo pins **`cloudera.cluster` v4.4.0** (see `requirements.yml`). That release includes `cm_service` and `cm_config` modules but **not** `cm_autotls` or `cm_kerberos` (those appear in newer collection branches). We keep **REST** for Auto-TLS, LDAP, Kerberos, and CMS lifecycle to avoid a collection upgrade and to match Jenkins/controller reachability patterns.

### Run order (`pvc_setup.sh` / Jenkins `CM_TLS_KRB_LDAP`)

| Step | This repo | Labs tag / role |
|------|-----------|-----------------|
| 1 | `27_setup_cm_autotls.yml` | `cm_autotls` — generateCmca, CM restart, agent reconcile, optional CMS trust + restart |
| 2 | `28_setup_cm_cms.yml` | `cm_service` — roles on `cloudera_manager`, 6 GiB Service Monitor, Reports Manager DB |
| 3 | `29_setup_cm_ldap.yml` | `external_auth` / `cm_config` LDAP keys |
| 4 | `30_setup_cm_krbs.yml` | `cm_kerberos` — KDC import, bounded `kerberized` wait |

### Labs vs this repo (behavior)

| Area | Cloudera Labs reference | This repo | Notes |
|------|-------------------------|-----------|--------|
| **CMS** | `cloudera.cluster.cm_service` | REST in `configure_cm_cms_api.yml` | Same role types, `firehose_non_java_memory_bytes` (6 GB), Reports Manager PostgreSQL host = `cldr-mngr` FQDN (`cm_cms_reports_manager_db_host` → `postgresql` group equivalent) |
| **Auto-TLS** | `cm_autotls` module + CA on CM host | REST `POST /cm/commands/generateCmca` in **27** | MGMT `ssl_client_truststore_*` via REST; CMS restart after Auto-TLS when MGMT exists (`reconcile_cm_cms_after_autotls.yml`) |
| **LDAP** | `cm_config` + optional `external_user_mappings` | REST `PUT /cm/config` in `configure_cm_ldap_api.yml` | No separate mappings task unless you add `cm_ldap_external_user_mappings` later |
| **Kerberos** | `cm_kerberos` module | REST in `configure_cm_kerberos_api.yml` + **28** import credentials | **AES-only** `krb5_enc_types` (Labs samples often include RC4) |
| **CM HTTPS access** | Caddy/reverse_proxy on ops → `https://cm…:7183` | Direct `https://<cldr-mngr-fqdn>:7183` | Portal Caddy on **`ipaserver`** (or `cldr-mngr`) is portal/pgAdmin/monitoring/IPA only — not CM API proxy |
| **Inventory** | `cloudera_manager`, `postgresql`, `reverse_proxy` groups | `cldr-mngr`, `ipaserver`, `deployment_portal_host_group` | Postgres for CM/CMS on `cldr-mngr`; FreeIPA on `ipaserver` |
| **Agents** | Restart after Auto-TLS | `reconcile_cm_agents.yml` at end of **27** | Preserved — do not skip |

Module migration (optional future): `cm_service` could replace CMS REST where `cloudera_manager_api_*` facts are set; not required for Labs parity because REST already mirrors role config groups and start/restart commands.

---

## Configuration (`group_vars/all.yml`)

### Core versions

| Variable | Default | Description |
|---|---|---|
| `java_version` | `17` | OpenJDK version |
| `python_version` | `3.11` | Python version (packages and module enablement) |
| `postgresql_version` | `18` | PostgreSQL version |
| `postgres_amazon_linux_2023_native_client_version` | (computed) | Native Amazon Linux 2023 `psql` client package version (`min(postgresql_version, 17)`); CM DB tasks on `cldr-mngr` may use this while the server stays `postgresql_version` |
| `cm_version` | `7.13.2.10000` | Cloudera Manager version |
| `cdh_version` | `7.3.2.10000` | CDH parcel version |

**`python_version` scope:** On targets, this drives `os_vars` package names (`python{{ python_version }}`, pip/devel or venv/dev packages), RHEL 8 `dnf module enable python<version>`, and on RedHat the `python{{ python_version }}` / `pip{{ python_version }}` executables used in **06_prereq_setup.yml** for install and pip upgrade. It does **not** fully align every Python path in the repo:

| Area | Behavior |
|---|---|
| Ansible on targets | `ansible.cfg` sets `interpreter_python = /usr/bin/python3`; remote modules use that unless you set `ansible_python_interpreter` in inventory or host vars |
| **06** / **23** psycopg2 | `psycopg2-binary` is installed with hardcoded `pip3` and verified with `/usr/bin/python3` (Ansible's default interpreter), not `python{{ python_version }}` |
| Debian pip upgrade | `os_vars.Debian.pip_executable` is `pip3`; **06** pip upgrade uses it even when `python_version` changes |
| `psycopg2_binary_version` | Pins the **library** on pip install (`psycopg2-binary==…` when set); does not select the Python minor version |

### Cluster names

| Variable | Default |
|---|---|
| `cdh_basecluster_name` | `CDH-Cluster` |
| `base_cluster_install_services` | see `all.yml` | Per-service booleans for `31_setup_base_cluster.yml` (Spark 3, Knox, and Solr default `true`; NiFi, NiFi Registry, DataViz, and Phoenix default `false`; Iceberg validates its engine services) |
| `cm_admin_bootstrap_pass` | `admin` | Factory CM password; when `cm_admin_pass` differs, `ensure_cm_admin_password.yml` runs in **24_start_cm** / **27_setup_cm_autotls** only |
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
| `parcel_repo` | computed | Public or internal CDH parcel URL (`…/p/cdh7/<cdh_version>/parcels/`) |
| `parcel_repo_latest_public` | computed | `…/p/cdh7/latest/parcels/` when `cm_parcel_repo_include_latest` (literal segment `latest` — **not** `{latest}`) |
| `ecs_parcel_repo_url` | computed | `…/p/cdp-pvc-ds/<ecs_pvc_ds_version>/parcels/` (see `ecs_pvc_ds_version` in ECS table above) |
| `ecs_parcel_repo_latest_url` | computed | `…/p/cdp-pvc-ds/latest/parcels/` when `cm_parcel_repo_include_latest` |
| `cm_parcel_repo_include_latest` | `false` | When true, add literal `…/latest/parcels/` paths (never `{latest}` — invalid URI and not on archive) |
| `cm_parcel_repo_latest_segment` | `latest` | Archive path segment when include_latest is true |
| `cdv_parcel_repo_url` | computed | CM remote parcel repo: `…/cdv/<ver>/parcels/` (not `…/redhat8/yum` — JAR downloads only) |
| `cfm_parcel_yum_tars_repo_url` | computed | CM remote parcel repo: `…/cfm2/<ver>/redhat9/yum/tars/parcel` (not `…/cfm2/<ver>/parcels/`) |
| `cdv_parcel_repo_latest_url` | computed | Optional `…/cdv/latest/parcels/` when include_latest |
| `cm_parcel_repo_include_cdv_parcel` | `true` | Include CDV parcel repo URLs in CM config |
| `cm_parcel_repo_include_cfm_parcel` | `true` | Include CFM2 parcel repo URLs (NiFi + NiFi Registry) |
| `cm_parcel_csd_respect_service_toggles` | `false` | When false, CDV/CFM parcel URLs are set even if `base_cluster_install_services` keys are off |
| `cm_remote_parcel_repo_intel_mkl_url` | Intel MKL parcels | Optional third-party parcel repo (left enabled by default) |
| `cm_parcel_repo_merge_existing_cm_urls` | `false` | When false, CM wizard defaults are not merged (only Ansible URLs + scrub) |
| `cm_parcel_install_csd_repo_urls` | `false` | Maps to CM `PARCEL_INSTALL_CSD_REPO_URLS` (blocks auto spark/cdh6 URLs on restart) |
| `cm_remote_parcel_csd_repo_urls` | `[]` | Explicit CSD archive dirs; empty = build from `scm_csd_parcel_repo_urls.j2` |
| `cm_parcel_repo_include_csd_archive_dirs` | `true` | Add CDV/CFM archive paths to `REMOTE_PARCEL_REPO_URLS` |
| `scm_parcel_repositories` | computed | Legacy `scm.j2` list: pinned + latest CDH/ECS, CDV/CFM parcels, Intel MKL |
| `cdh_parcel_os_suffix` | `auto` | Parcel filename suffix: `auto`, `el8`, `el9`, `jammy`, `noble`, `sles15`, `el8.aarch64le` |
| `cdh_parcel_target_group` | `base-workers` | Inventory group used to auto-detect worker OS for parcel suffix |
| `cdh_parcel_os_suffix_fallback` | `el8` | Fallback when auto-detect cannot read worker facts |
| `target_cpu_architecture` | `auto` | `auto`, `x86_64`, or `arm64` — set by wrapper when `CPU_ARCHITECTURE=arm64` |
| `ecs_deploy_on_arm64` | `false` | Allow ECS on ARM64/Graviton (experimental) |
| `cdh_parcel_arm64_suffix` | `.aarch64le` | Appended to parcel suffix on ARM64 workers when `auto` |
| `scm_csds` | `[]` | **Override:** non-empty list of full CSD `.jar` URLs for `24_start_cm` `get_url` (replaces `scm_csds_urls.j2`) |
| `scm_csds_redhat` | `[]` | Same as `scm_csds` when that list is empty (RHEL CM hosts only) |
| `cdv_version` | `8.0.7` | Cloudera Data Visualization (CDV) CSD path version, e.g. `8.1.5` |
| `cdv_dataviz_csd_jar` | `DATAVIZ-{{ cdv_version }}-…` | DATAVIZ CSD jar basename under `cdv/<version>/<redhat8\|9>/yum/` |
| `cdv_dataviz_parcel_build` / `cdv_dataviz_parcel_file` | build + optional full name | CDV parcel under `cdv/<version>/parcels/` when yum CSD jar is missing |
| `cdv_redhat_yum_repo` | `auto` | CDV yum repo dir: `auto` uses `redhat8` on RHEL 9 CM when needed, or `redhat8` / `redhat9` |
| `cfm_version` | `2.1.7.3004` | Cloudera Flow Management (NiFi) CSD path version |
| `cfm_nifi_app_version` | `1.28.1` | NiFi app version segment in `NIFI-*.jar` / `NIFIREGISTRY-*.jar` |
| `cfm_nifi_csd_jar` / `cfm_nifi_registry_csd_jar` | computed | Jar basenames under `cfm2/<cfm_version>/…/parcel/` |
| `csd_redhat_repo` | `auto` | `redhat8`, `redhat9`, or `auto` from CM host OS |
| `csd_build_urls_enabled` | `true` | Build CSD URLs from version vars on RHEL when lists above are empty |
| `csd_respect_service_toggles` | `true` | Only include CSDs for enabled `base_cluster_install_services` keys |
| `cm_repo_username` | — | Required (archive credentials) |
| `cm_repo_password` | — | Required (archive credentials) |

**CSD JAR override vs default:** Leave `scm_csds` and `scm_csds_redhat` empty (default) and set `cdv_version`, `cfm_version`, and jar basename vars — play **24** builds `scm_csds_effective` via `scm_csds_urls.j2` (DATAVIZ + NiFi + Registry when toggles allow) and `get_url`s each URL. DATAVIZ yum failures ignore errors so `download_cdv_dataviz_csd.yml` can extract the jar from the CDV parcel. To override all CSD URLs, set `scm_csds` to a YAML list of full `https://…/*.jar` strings (same shape the template emits). `scm_csds_effective` is computed in `set_os_facts.yml`: explicit list → else `scm_csds_redhat` → else `scm_csds_urls.j2` on RHEL when `csd_build_urls_enabled` is true.

**CSD JAR downloads vs CM remote parcel repo directories:** Do not reuse the same URL for both. NiFi/Registry JARs use `get_url` on `scm_csds_effective` in **24_start_cm.yml**. CM **REMOTE_PARCEL_REPO_URLS** (playbooks **25** / **31** / **33** via `configure_cm_parcel_repo_api.yml`) must list **archive directory** URLs only, from `scm_csd_parcel_repo_urls.j2` unless `cm_remote_parcel_csd_repo_urls` is set (still driven by `cdv_version` / `cfm_version` when auto-built). NiFi and NiFi Registry share one CFM parcel directory; the parcel template dedupes with Jinja `unique` when both services are enabled.

| Purpose | Template / vars | Example (public archive, RHEL 8 CM) |
|---|---|---|
| DATAVIZ CSD JAR `get_url` | `scm_csds_urls.j2` (+ parcel fallback in `download_cdv_dataviz_csd.yml`) | `…/p/cdv/8.0.7/redhat8/yum/DATAVIZ-8.0.7-b50.p1.71299628.jar` |
| NiFi / Registry CSD JAR `get_url` | `scm_csds_urls.j2` or explicit `scm_csds` | `…/p/cfm2/2.1.7.3004/redhat8/yum/tars/parcel/NIFI-1.28.1.2.1.7.3004-1.jar` (two jars when both services enabled) |
| CM remote parcel repo dir (DATAVIZ) | `scm_csd_parcel_repo_urls.j2`, `cdv_parcel_repo_url` | `…/p/cdv/8.0.7/parcels/` |
| CM remote parcel repo dir (CFM / NiFi) | same, `cfm_parcel_yum_tars_repo_url` | `…/p/cfm2/2.1.7.3004/redhat9/yum/tars/parcel` |

On RHEL 9 CM hosts, CDV JAR paths may still use `redhat8/yum` (`cdv_redhat_yum_repo: auto`); CFM uses `redhat9/yum/…` from `csd_redhat_repo: auto`. Parcel repo scrub in `configure_cm_parcel_repo_api.yml` drops any candidate URL matching `\.jar`.

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
| No ipaserver + non-empty `ad_kdc_host` | `ad` | Dependent: 11, 14, 23, 25 |
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
| `krb5_enc_types` | Space-separated CM `KRB_ENC_TYPES` (default `aes256-cts aes128-cts`) |
| `krb5_allow_weak_rc4` | `false` — set `true` only if legacy RC4 clients are required (not recommended; Java 17+ disables RC4) |
| `krb5_ipa_default_enctypes` / `krb5_ipa_permitted_enctypes` | Long krb5 names for FreeIPA KDC `krb5.conf.d` snippet (`configure_ipa_krb_enc_types.yml`) |

### Active Directory variables

| Variable | Description |
|---|---|
| `ad_domain` | AD DNS domain |
| `ad_kdc_host` | AD DC IP or hostname (default empty — set for AD; placeholders break `auto`) |
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
| AWS (FreeIPA clients) | cluster domain + `{region}.compute.internal` | IPA server IP, then VPC resolver `x.y.0.2` |
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
| `ensure_collections.yml` | Galaxy install from `requirements.yml` (imported by every playbook; same logic as `pvc_setup.sh`) |
| `01_install_collection.yml` | Imports `ensure_collections.yml`; pins DNF `$releasever` before any package operation (and subscription-manager when available), then updates only within that RHEL minor |
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
| `detect_identity.yml` | Detect FreeIPA vs AD |
| `11_identity_setup.yml` | Phase 2 router (all of 10–15) |
| `12_setup_freeipa_server.yml` | FreeIPA server (skipped for AD) |
| `ipa_deep_recovery.yml` | Optional IPA detect/recover/sanitize before playbook 12 |
| `13_update_resolv_conf.yml` | DNS (netplan or resolv.conf) |
| `14_setup_dns_records.yml` | FreeIPA DNS records (skipped for AD) |
| `16_setup_identity_client.yml` | FreeIPA client or AD realm join |
| `18_setup_ad_client.yml` | AD realm join only |
| `17_setup_freeipa_client.yml` | FreeIPA client only |
| `19_setup_wildcard.yml` | `*.apps` wildcard DNS (FreeIPA only) |

### Phase 3 — Cloudera Manager

**Auto-TLS default:** `autotls_enabled` defaults to **`true`** in `group_vars/all.yml` (override with Jenkins `ANSIBLE_GROUP_VARS_YAML` or `-e autotls_enabled=false` for manual TLS only). Playbook **`27_setup_cm_autotls.yml`** is **not** part of **`CM_INSTALL`** / `DEPLOY_PHASE=3` — it runs in the next stage (**`CM_TLS_KRB_LDAP`** / `cm_tls`, legacy phase 4) after CM is up on HTTP `:7180`. With the default, **27** calls **`POST /cm/commands/generateCmca`**, restarts CM, and reconciles agents so the **CM UI is HTTPS on `:7183`** (Cloudera Auto-TLS, not a hand-installed cert). Jenkins **`CM_INSTALL` alone** leaves CM on `:7180` until **`CM_TLS_KRB_LDAP`** (or `DEPLOY_PHASE=all`).

| Playbook | Description |
|---|---|
| `20_setup_cm_repos.yml` | **Repo router** — internal web + mirror or public archive config |
| `21_setup_internal_repo.yml` | Internal HTTP repo web server (skipped when `cm_repo_source=public`) |
| `22_download_repos.yml` | Mirror from archive (internal) or configure public `archive.cloudera.com/p/` repos |
| `23_setup_postgres.yml` | PostgreSQL for CM |
| `24_start_cm.yml` | Install/start CM server + agents |
| `25_verify_cm.yml` | Verify CM is running |
| `reconcile_cm_agents.yml` | Reconcile CM agent `server_host` / `use_tls` and restart agents |
| CM API on **HTTP :7180** (Auto-TLS off) | Agents must use **`use_tls=0`** | **27** / **25** set `use_tls=0` in `config.ini` when CM reports Auto-TLS disabled — agents cannot speak TLS to an HTTP-only CM server. CMS TLS trust reconcile in **27** is skipped when Auto-TLS is off. |
| `26_setup_cm_license.yml` | Upload license or trial |
| `27_setup_cm_autotls.yml` | Enable Auto-TLS; agent reconcile; CMS trust/restart when MGMT already exists |
| `28_setup_cm_cms.yml` | CMS — run **before** LDAP/Kerberos in `cm_tls` phase |
| `29_setup_cm_ldap.yml` | LDAP auth (FreeIPA or AD) — run **before** **30** |
| `30_setup_cm_krbs.yml` | Kerberos (FreeIPA or AD KDC); PUT `/cm/config`, `POST /cm/commands/importAdminCredentials` (query params), CM restart; bounded wait on `kerberosInfo.kerberized` |

### Phase 4 — CMS & base cluster

CMS (Management Service) and CDP base cluster are **separate**:

| Playbook | Component | Deploys |
|---|---|---|
| `28_setup_cm_cms.yml` | CMS | Service Monitor, Host Monitor, Event Server, etc. Run **after** `27_setup_cm_autotls.yml` when Auto-TLS is on. |

**CMS troubleshooting (Service Monitor / Avro `Connection refused`):**

| Symptom | Likely cause | Operator checks |
|---|---|---|
| `AvroRuntimeException: Connection refused` in CM UI / debug bundles | Service Monitor (firehose) not listening — crashed, OOM, or still starting | `28_setup_cm_cms.yml` now waits on the firehose TCP port; on `cldr-mngr`: `/var/log/cloudera-scm-firehose/`, `/var/run/cloudera-scm-agent/process/*-SERVICEMONITOR*/logs/` |
| JMX `smonStatusRequest` / `smonReportRequest` Count 0 | CM cannot reach Service Monitor Avro endpoint | Confirm role **RUNNING** in CM → Management Service; `ss -ltn` on loopback for firehose port from role config |
| `ImportCredentials - Execution error` in `cloudera-scm-server.log` | TLS / credential store mismatch after Auto-TLS | Ensure MGMT `ssl_client_truststore_*` points at agent `cm-auto-global_truststore.jks` (automation in `configure_cm_cms_autotls_trust.yml`); re-run **27** then **28** |
| Reports Manager won't start / **28** fails RM DB probe | Postgres `rman` DB missing (partial **23** init) or TCP auth from CM host | **28** runs `ensure_cm_postgres_databases` before probe; re-run **23** or **28**. From CM host: `psql -h <postgres-fqdn> -U rman -d rman`; logs: `/var/log/cloudera-scm-headlamp/` |
| **Hosts: Last Heartbeat ~minutes** (all commissioned) | **CM agent** not checking in to CM Server (not a browser refresh issue) | `systemctl status cloudera-scm-agent`; `grep ^server_host= /etc/cloudera-scm-agent/config.ini` (cldr-mngr FQDN); after Auto-TLS `use_tls=1` — re-run **27** or **`reconcile_cm_agents.yml`**; agent log `/var/log/cloudera-scm-agent/cloudera-scm-agent.log`; chrony via **07** |
| **Hosts: load/disk/memory empty or stale** but heartbeat fresh | **Host Monitor** (CMS) not publishing host metrics | CM → Management Service: Host Monitor **RUNNING**; re-run **28_setup_cm_cms.yml** (after **27** when Auto-TLS on); firehose/agent logs on cldr-mngr |
| **Hosts: Tags column empty** | Tags are optional; not set at agent install | Enable `cm_host_tags_enabled` (default true) — **28** applies inventory role/env/owner tags via API |
| `31_setup_base_cluster.yml` | Base cluster | HDFS, Ozone, YARN, Hue, Tez, Hive, Hive on Tez, HBase, Core Settings, Iceberg, Replication Manager, Impala, Kafka, ZooKeeper, Atlas, Ranger; optional NiFi, NiFi Registry, DataViz, Phoenix, Knox, Solr (`base_cluster_install_services`) |
| `33_setup_ecs_cluster.yml` | ECS cluster | Phased DOCKER + ECS + embedded control plane — see [CDP_ECS_INSTALL.md](CDP_ECS_INSTALL.md) |
| `10_setup_deployment_portal.yml` | Ops portal bootstrap | Caddy, pgAdmin, optional monitoring on ops host (`auto` → ipaserver else cldr-mngr); run early in phase 1 |
| `32_setup_monitoring_stack.yml` | Monitoring only | Add monitoring after 28 (requires portal network): Prometheus/Grafana/Alertmanager/cAdvisor stack + node_exporter/process_exporter on cluster hosts + Grafana provisioning + Prometheus alert rules |
| `34_setup_ecs_data_services.yml` | ECS data services | CDW/CDE/CAI/Model Registry via `cloudera.cloud` + Caddy — see [CDP_ECS_DATA_SERVICES.md](CDP_ECS_DATA_SERVICES.md) |

**ECS API keys (automation):** IAM `createMachineUserAccessKey` requires a **signed** request. Password-only console login is not enough. After ECS is up, either set `ecs_api_access_key_id` / `ecs_api_private_key`, or set a **one-time** bootstrap admin key (`ecs_iam_bootstrap_*` or Jenkins `ECS_IAM_BOOTSTRAP_*` credentials) and enable `ecs_auto_provision_api_access_key` (default `true`) to create machine user `ecs_automation_machine_user` via CDP CLI; keys are cached at `ecs_api_credentials_cache_path`.
| `35_refresh_deployment_portal.yml` | Portal refresh | Re-render index/Caddy after CM, base, ECS, or DS changes (no full reinstall) |

Requires base cluster for `control_plane.datalake_cluster_name`. Uses `ecs-masters` / `ecs-workers` inventory groups. Skipped when `ecs_deploy_enabled: auto` and ECS groups are empty.

### Deployment portal & monitoring (`group_vars/all.yml`)

| Variable | Default | Description |
|---|---|---|
| `deployment_portal_enabled` | `true` | Run `10_setup_deployment_portal.yml` |
| `deployment_portal_host_group` | `auto` | `auto`, `ipaserver`, or `cldr-mngr` — where Caddy/pgAdmin/Grafana run |
| `postgres_inventory_group` | `""` (auto) | Pin Postgres install group; else `[postgres]` → `[postgresql]` → `[db]` → `cldr-mngr` |
| `postgres_inventory_group_resolved` | (computed) | Effective inventory group for `23_setup_postgres.yml` |
| `postgres_inventory_host` | (computed) | First host in resolved group — CM DB tasks delegate here (`ensure_cm_postgres_databases.yml`) |
| `postgres_host_fqdn` | (computed) | CM JDBC / Reports Manager / pgAdmin DB host FQDN |
| `postgres_ensure_cm_db_psql_host` | `""` (auto) | Optional `-e` override for delegated `psql -h` on `postgres_inventory_host` |
| `postgres_ensure_cm_db_psql_host_effective` | (computed) | Auto from `resolve_postgres_ensure_cm_db_psql_host.yml`: `postgres_host_fqdn`, else DB `private_ip`, else `ansible_host` (delegated on DB host) |
| `atlas_db_name` / `atlas_db_user` / `atlas_db_password` | `atlas` / `atlas` / `atlas` | Atlas JDBC when using external PostgreSQL; created in **23** via `databases` / `create_cm_dbs.sql.j2` |
| `clo_db_name` / `clo_db_user` / `clo_db_password` | `clo` / `clo` / `clo` | **Cloudera Lakehouse Optimizer** (CLO/DLM) metadata DB; created in **23** via `databases` |
| `deployment_portal_postgres_host_group` | `auto` | CM PostgreSQL host for pgAdmin (`auto` = same as `postgres_inventory_group_resolved`) |
| `deployment_portal_runs_on_ipaserver` | computed | True when `deployment_portal_host_group` explicitly selects IPA or `auto` selects an available IPA group |
| `deployment_portal_http_port` | `81` on IPA; `80` otherwise | Caddy index + Grafana/Prometheus/Alertmanager paths; explicit overrides win |
| `deployment_portal_ipa_https_enabled` | `true` | Serve the FreeIPA Caddy vhost over self-signed HTTPS and redirect its HTTP vhost to HTTPS |
| `deployment_portal_ipa_https_port` | `9443` on IPA; `443` otherwise | Caddy FreeIPA HTTPS listener; avoids IPA Apache and Dogtag PKI when colocated and uses the standard port on a dedicated proxy; explicit overrides win |
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
| `deployment_portal_expose_credentials` | `true` | Render **Operator access** panel (CM, DB, IPA, Ranger/Knox/Hue, ECS, optional Jenkins) from group_vars at portal sync |
| `deployment_portal_expose_ssh_keys` | `true` | Request copying controller SSH private keys to `/downloads/ssh/` (EC2 PEM and/or distinct Auto-TLS key). Export is always suppressed unless `deployment_portal_basic_auth_enabled` is true; set `false` to disable explicitly |
| `deployment_portal_ssh_pem_path` | `""` | Optional explicit path to the EC2/Ansible PEM on the controller (`sshkey.pem` auto-discovered when empty) |
| `deployment_portal_ssh_autotls_key_path` | `""` | Optional explicit Auto-TLS private key on the controller; otherwise uses `cm_private_key_path` / `id_rsa` discovery (same order as playbook 27) |
| `deployment_portal_basic_auth_enabled` | `true` | Enable portal login and revocable server-side sessions for `/downloads/*` (index and Tier A verify stay unauthenticated); variable name retained for compatibility |
| `deployment_portal_basic_auth_user` | `portal` | Portal session-login username |
| `deployment_portal_basic_auth_password` | `postgres_password` | Portal session-login password |
| `deployment_portal_auth_image` | `python:3.12-alpine` | Private, unexposed session-service container image |
| `deployment_portal_auth_container` | `cldr-portal-auth` | Session-service container name |
| `deployment_portal_session_ttl_seconds` | `28800` | Server-side portal session lifetime (8 hours); logout revokes the current token immediately |
| `deployment_portal_jenkins_url` | `""` | Optional Jenkins UI URL on the operator panel (passwords belong in Jenkins, not git) |
| `monitoring_prometheus_extra_targets` | `[]` | Extra Prometheus scrape jobs |
| `monitoring_node_exporter_enabled` | `true` | Install node_exporter (systemd) on `monitoring_node_exporter_host_groups` and add a `node_exporter` Prometheus job (playbook **32**) |
| `monitoring_node_exporter_version` | `1.8.2` | Pinned node_exporter release (linux amd64/arm64 tarball from GitHub releases) |
| `monitoring_node_exporter_port` | `19100` | node_exporter `--web.listen-address` port; opened in firewalld on each target host when active. The nonstandard default intentionally leaves common Kubernetes DaemonSet host port `9100` available. |
| `monitoring_node_exporter_bin_dir` | `/usr/local/bin` | Install path for the `node_exporter` binary |
| `monitoring_node_exporter_user` / `monitoring_node_exporter_group` | `node_exporter` | Dedicated system user/group running the systemd service (no login shell) |
| `monitoring_node_exporter_download_base_url` | GitHub releases URL | Override for an internal mirror when GitHub egress is restricted |
| `monitoring_node_exporter_host_groups` | `[ipaserver, cldr-mngr, base-masters, base-workers, ecs-masters, ecs-workers]` | Inventory groups that get node_exporter + a scrape target; targets always use `private_ip` (Prometheus container reaches cluster hosts over the VPC/private network) |
| `monitoring_process_exporter_enabled` | `true` | Install process_exporter (systemd) on `monitoring_process_exporter_host_groups` and add a `process_exporter` Prometheus job (playbook **32**) — per-process CPU/memory metrics |
| `monitoring_process_exporter_version` | `0.8.7` | Pinned process_exporter release (linux amd64/arm64 tarball from GitHub releases) |
| `monitoring_process_exporter_port` | `19256` | process_exporter `--web.listen-address` port; opened in firewalld on each target host when active. The nonstandard default leaves conventional exporter host port `9256` available to Kubernetes workloads. |
| `monitoring_process_exporter_bin_dir` | `/usr/local/bin` | Install path for the `process-exporter` binary |
| `monitoring_process_exporter_user` / `monitoring_process_exporter_group` | `process_exporter` | Dedicated system user/group running the systemd service (no login shell) |
| `monitoring_process_exporter_config_dir` | `/etc/process_exporter` | Rendered `config.yml` (process_names matchers) on each target host |
| `monitoring_process_exporter_host_groups` | same six groups as `monitoring_node_exporter_host_groups` | Inventory groups that get process_exporter + a scrape target; override to narrow scope independently of node_exporter |
| `monitoring_process_exporter_process_names` | see `group_vars/all.yml` | Named cmdline-regex matchers (`cloudera-scm-server`, `postgres`, `java`, `docker`, …) grouping per-process metrics; first match wins |
| `monitoring_process_exporter_catch_all` | `true` | Append a `{{.Comm}}` matcher grouping every other process by executable name |
| `monitoring_grafana_provisioning_enabled` | `true` | Render Grafana datasource + dashboard provisioning YAML and copy the prepopulated dashboard JSON under `{{ monitoring_config_dir }}/grafana/` (playbook **32** / portal sync) |
| `monitoring_alert_rules_enabled` | `true` | Render Prometheus alerting rules (`InstanceDown`, `HostHighCpuLoad`, `HostHighMemoryUsage`) to `{{ monitoring_config_dir }}/rules/alerts.yml` |
| `monitoring_alert_instance_down_for` | `2m` | `for:` duration before `InstanceDown` fires |
| `monitoring_alert_high_cpu_threshold` / `monitoring_alert_high_cpu_for` | `85` / `10m` | CPU busy % threshold and duration for `HostHighCpuLoad` |
| `monitoring_alert_high_mem_threshold` / `monitoring_alert_high_mem_for` | `90` / `10m` | Memory used % threshold and duration for `HostHighMemoryUsage` |
| `monitoring_alertmanager_group_by` | `[alertname, severity]` | Alertmanager `route.group_by` |
| `monitoring_alertmanager_receiver_webhook_url` | `""` | Optional webhook URL added to the `default` Alertmanager receiver (empty = no external notification integration, alerts still visible in the UI) |
| `caddy_vhost_enabled` | `true` | Host-based Caddy URLs (nip.io-style) |
| `caddy_vhost_public_base` | `pvc.cloudera-labs.com` | Base domain for `svc.<ip-dashed>.<base>` |
| `caddy_vhost_dns_mode` | `embedded_ip` | `embedded_ip`, `classic_nipio`, or `flat` |
| `caddy_vhost_service_names.cadvisor` | `cadvisor` | Hostname prefix for cAdvisor lab vhost (`cadvisor.<ip-dashed>.<base>:81` → container **8080**) |
| `autotls_enabled` | `true` | Cloudera Auto-TLS (generateCmca); set `false` for manual TLS on `:7183` only |
| `portal_automation_owner_display` | `Kuldeep Sahu` | **Portal** badge — automation/repo author (not the EC2 deployment owner) |
| `deployment_owner` | `""` | **Deployment owner** badge — from `.tfvars.yaml` `owner`, Jenkins `OWNER`, Terraform `pvc_cluster_tags.owner` |
| `deployment_name_prefix` | `""` | **Prefix** badge — from `.tfvars.yaml` `environment`, Jenkins `ENVIRONMENT`, Terraform workspace + `{environment}-*` resource names |
| `ec2_startstop_script_name_prefix` | `""` | Optional override for ipaserver script filename prefix; when empty uses sanitized `deployment_name_prefix` → `{prefix}_cldr_ec2_strt_stp.sh` under `ec2_startstop_script_dir` (`/root`) |
| `ec2_startstop_script_path` | *(derived)* | Full path to deployed start/stop script (playbooks **36** / **37**); override to pin a custom location |
| `ec2_startstop_script_basename` | *(derived)* | Filename only, e.g. `ptgtyv1_cldr_ec2_strt_stp.sh` — used in template header and docs |
| `ec2_startstop_excluded_terraform_groups` | `ipa_server` | Group tag values omitted from start/stop examples and blocked for start/stop in script **37** / Jenkins |
| `ec2_startstop_terraform_group_catalog` | `.tfvars.yaml` keys (no `ipa_server`) | Default Terraform `instance_groups` / EC2 tag `Group` values when inventory is empty at template time |
| `ec2_startstop_ansible_to_terraform_group` | *(map)* | Ansible inventory group → EC2 tag `Group` (e.g. `base-masters` → `pvcbase_master`) |
| `ec2_startstop_inventory_group_scan_order` | ordered list | Which Ansible groups to scan when building example argv (only non-empty groups are included) |
| `deployment_portal_ec2_startstop` | *(derived at portal sync)* | Rendered from `ec2_startstop_portal_facts.j2` → `deployment_portal_context.ec2_startstop` (usage + example commands) |

### Lab default passwords (override before production)

Literal defaults from `group_vars/all.yml`. The portal **Operator access** panel and `/downloads/operator-credentials.json` mirror these at sync time (not committed to git). Several services share **`postgres_password`** via Jinja. Operator-focused portal behavior (downloads auth, JSON bundle, overrides): [OPERATIONS_GUIDE.md — Deployment portal default credentials](OPERATIONS_GUIDE.md#deployment-portal-default-credentials).

| Service / use | Ansible variable(s) | Default (lab) |
|---------------|---------------------|-----------------|
| FreeIPA | `ipaadmin_principal`, `ipaadmin_password` | `admin` / `PseTeam@123` (`common_password` aliases IPA password) |
| PostgreSQL | `postgres_password` | `postgres` |
| Portal `/downloads/*` session login | `deployment_portal_basic_auth_user`, `deployment_portal_basic_auth_password` | `portal` / **`postgres_password`** |
| Cloudera Manager | `cm_admin_user`, `cm_admin_pass` | `admin` / `admin` (factory bootstrap `cm_admin_bootstrap_pass`: `admin`) |
| pgAdmin | `pgadmin_default_email`, `pgadmin_default_password` | email pattern in table above / **`postgres_password`** |
| Grafana (monitoring stack) | `monitoring_grafana_admin_user`, `monitoring_grafana_admin_password` | `admin` / **`postgres_password`** |
| EC2 SSH | `ansible_user` / inventory | `ec2-user` (keys under `/downloads/ssh/` when `deployment_portal_expose_ssh_keys: true`) |

**`operator-credentials.json`:** top-level `basic_auth_enabled`, `auth_username`, `downloads_path_prefix`; `sections[]` with `credentials[]` (`label`, `username`, `password`, `url`, `note`) — see `deployment_portal_operator_credentials.json.j2`.

**Portal index attribution:** `build_deployment_portal_facts.yml` sets `deployment_portal_context.deployment` from the vars above. Wrapper/Jenkins load tfvars (`scripts/lib/parse_tfvars_yaml.py` maps `owner`→`OWNER`, `environment`→`ENVIRONMENT`); `pvc_setup.sh` / `jenkins/scripts/render-ansible-group-vars-override.py` pass `OWNER`/`ENVIRONMENT` into Ansible as `deployment_owner` / `deployment_name_prefix` via `jenkins_override.yml`. Empty values omit the deployment badges.

**SSH key files (controller vs portal host):** Portal sync reads private keys only from the **Ansible controller** (Jenkins agent workspace or laptop): `ansible-playbooks/sshkey.pem` (Terraform/Jenkins copy), optional `ansible-playbooks/id_rsa`, `ANSIBLE_PRIVATE_KEY`, `~/.ssh/id_rsa`, and optional `deployment_portal_ssh_pem_path` / `deployment_portal_ssh_autotls_key_path` / `cm_private_key_path`. The ops host receives **copies** under the portal www tree at `/downloads/ssh/` named like Terraform (`{ENVIRONMENT}-pvc-new-keypair.pem` / `KEYPAIR_NAME.pem`; same bytes as `sshkey.pem` on the controller) plus `cluster-autotls-id_rsa` when Auto-TLS key differs. Sync removes **stale basenames** only (for example after keypair rename or when EC2 and Auto-TLS keys dedupe to one file); unchanged keys are updated in place via `copy` checksum. Never commit keys to git.

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
| `2` | `identity` | `detect_identity.yml`, `11_identity_setup` |
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
| `ansible.posix` | POSIX helpers (`firewalld`) |
| `community.crypto` | TLS/crypto |
| `freeipa.ansible_freeipa` | FreeIPA server/client, ECS LDAP admin user |
| `cloudera.cluster` (git `v4.4.0`) | CM cluster API (`cloudera.cluster.cluster`) — playbooks 31, 33 |
| `cloudera.cloud` (git `v2.5.1`) | ECS control plane — `env_info`, `dw_*`, `de`, `ml` — playbook 34, ECS LDAP IAM |

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
| `common_tasks/configure_cm_agent.yml` | Set `server_host` (and `use_tls` when Auto-TLS) in agent `config.ini` |
| `common_tasks/reconcile_cm_agents.yml` | Configure agent + restart + wait for `active` |
| `common_tasks/apply_cm_host_tags.yml` | PUT `/hosts/{fqdn}/tags` from inventory groups |
| `common_tasks/verify_cm_host_heartbeats.yml` | Fail when commissioned hosts exceed `cm_host_heartbeat_max_age_seconds` |
| `common_tasks/set_cm_mirror_facts.yml` | Internal mirror URL facts |
| `common_tasks/mirror_internal_cm_rhel.yml` | RPM mirror + createrepo |
| `common_tasks/mirror_internal_cm_apt.yml` | apt `.deb` mirror + Packages index |
| `common_tasks/install_postgresql_repo.yml` | PGDG repo per OS |
| `common_tasks/init_postgresql.yml` | PostgreSQL init |
| `common_tasks/restart_postgresql.yml` | OS-aware PostgreSQL restart |
| `common_tasks/disable_firewall.yml` | firewalld (RHEL) or ufw skip |
| `common_tasks/join_ad_realm.yml` | AD `realm join` |
| `common_tasks/join_freeipa_client.yml` | IPA client enrollment (detect partial state, optional uninstall, preflight, `ipa-client-install`, fail diagnostics) |
| `common_tasks/detect_ipa_client_install_state.yml` | `default.conf` vs partial client debris (`/var/lib/ipa-client/sysrestore`, `/etc/ipa` fragments) before enroll |
| `common_tasks/preflight_ipa_client_install.yml` | Optional hostname/DNS/`getent` asserts before `ipa-client-install` when **`ipa_client_preflight_enabled: true`** (default **`false`**) on hosts without `/etc/ipa/default.conf` |
| `common_tasks/ensure_krb5_ansible_ccache_note.yml` | Comment-only **`/etc/krb5.conf.d/ansible-ccache-note.conf`**; play **12** / **16**; **SSSD restart** on clients when drop-in changes and SSSD is active |
| `common_tasks/ensure_krb5_default_ccache_commented.yml` | **Clients:** comment KEYRING **`default_ccache_name`** (`krb5_libdefaults_default_ccache_commented_line`). **ipaserver:** restore active KEYRING unless **`krb5_comment_default_ccache_on_ipaserver: true`**; play **12** / **16** / **`join_freeipa_client`**; **`ipactl`** / **SSSD** restart when krb5.conf changes |
| `common_tasks/restart_sssd_after_krb5_ccache_note.yml` | Helper for krb5.conf.d / main krb5.conf client adjustments |
| `common_tasks/ensure_ipa_httpd_behind_caddy_before_client.yml` | Playbook **16** localhost play: resolve Caddy gate and **`build_deployment_portal_facts.yml`** before client enroll |
| `common_tasks/sync_ipa_httpd_caddy_proxy_state_on_ipaserver.yml` | Playbook **16** **`[ipaserver]`** play: load portal facts; **`manage_ipa_httpd_caddy_proxy_on_ipaserver.yml`** (cleanup by default; apply + **`preflight_ipa_json_on_ipaserver.yml`** only when **`deployment_portal_ipa_httpd_proxy_enabled`**) |
| `common_tasks/manage_ipa_httpd_caddy_proxy_on_ipaserver.yml` | **`configure_ipa_httpd_behind_caddy.yml`** when **`deployment_portal_ipa_httpd_proxy_enabled`**; else **`remove_ipa_httpd_caddy_proxy_on_ipaserver.yml`**; then **`sync_ipa_httpd_disable_browser_krb_on_ipaserver.yml`** when **`ipa_httpd_disable_browser_krb_negotiate`** (default **true**) |
| `common_tasks/sync_ipa_httpd_disable_browser_krb_on_ipaserver.yml` | **`zz-ipa-disable-browser-krb.conf`** (`SetEnv gssapi-no-negotiate` on `/ipa`); play **12**, PORTAL/**16** via **manage**; httpd reload — survives **`ipactl restart`** |
| `common_tasks/remove_ipa_httpd_caddy_proxy_on_ipaserver.yml` | Default: absent **`zz-ipa-caddy-proxy.conf`**, revert **`ipa-rewrite`** Caddy markers, httpd reload |
| `common_tasks/apply_ipa_httpd_behind_caddy_on_ipaserver.yml` | Deprecated alias → **`sync_ipa_httpd_caddy_proxy_state_on_ipaserver.yml`** |
| `common_tasks/preflight_ipa_json_on_ipaserver.yml` | POST **`/ipa/json`** on ipaserver after opt-in httpd apply — fail on HTML (not run on default Caddy-only play **16** path) |
| `common_tasks/configure_ipa_httpd_behind_caddy.yml` | **Opt-in** only: **`zz-ipa-caddy-proxy.conf`**, **`ipa-rewrite.conf`**, httpd reload (via **manage** when flag **true**) |
| `common_tasks/ensure_ipa_kdc_services.yml` | `ipactl start` + krb5kdc health on ipaserver |
| `common_tasks/detect_ipa_server_install_state.yml` | `default.conf`, partial debris, `ipactl` / `ipa-server-status` before `ipa-server-install` |
| `common_tasks/recover_ipa_server_install.yml` | Deeper `ipa-server-install --uninstall` + path cleanup (via `ipa_deep_recovery.yml`, not default playbook **12**) |
| `common_tasks/sanitize_ipa_paths_before_fresh_install.yml` | Remove broken or incomplete `/var/lib/ipa` (missing or stale **sysrestore**), `/etc/ipa`, and `/etc/dirsrv/slapd-*` before fresh install when `ipactl` not configured (playbook 12) |
| `common_tasks/preflight_ipa_server_install.yml` | Compact preflight for playbook 12: RHEL RPMs, `/etc/ipa` + `ipa_server_etc_ipa_subdirs`, `/var/lib/ipa` + `ipa_server_var_lib_subdirs`, openldap assert, `hostname -f`/`getent` asserts, **LDAP 389/636 listener check** when **`ipactl`** not configured |
| `ipa_deep_recovery.yml` | Optional detect / recover / sanitize before playbook 12 (set `ipa_server_deep_recovery: true`) |
| `common_tasks/resolve_ipa_install_dns_forwarders.yml` | VPC vs `--no-forwarders` flags for `ipa-server-install` (playbook 12) |

Playbook **`12_setup_freeipa_server.yml`** imports **`detect_ipa_server_install_state.yml`** and skips **`ipa-server-install`** when **`ipa --version`** is OK, **`ipa_server_has_default_conf`** is true, **`ipactl`** does not report **IPA is not configured**, and there is no partial install debris (**`ipa_server_has_partial_state`**). A non-zero **`ipactl`** rc from stopped services alone does **not** trigger reinstall; **`ensure_ipa_kdc_services.yml`** runs after the play. Install (and best-effort **`ipa-server-install --uninstall`**) runs when the host is not configured, partial/broken, or **`ipa_server_install_force: true`**. DNS forwarder argv comes from **`resolve_ipa_install_dns_forwarders.yml`**.

| `dns_forwarders` | `no` | Playbook **12**: AWS EC2 → VPC `--forwarder`; else `--no-forwarders`. See **`ipa_server_install_use_vpc_dns_forwarder`**. |
| `ipa_server_install_use_vpc_dns_forwarder` | `true` | When **`dns_forwarders: no`**, use VPC resolver on AWS at install (and **`dnsconfig-mod`** when install skipped). |
| `ipa_server_deep_recovery` | `false` | When **`true`**, run playbook **`ipa_deep_recovery.yml`** before **12** for automated detect/recover/sanitize. |
| `common_tasks/preflight_kdc_reachable.yml` | TCP :88 to `kdc_host` before CM Kerberos REST; from **cldr-mngr** when `ansible_control_reachability` is `public` (Jenkins) |
| `common_tasks/verify_cm_kerberos_enabled.yml` | Bounded wait on `/cm/kerberosInfo` field `kerberized`; actionable fail (see `cm_krb_kerberized_wait_*` in `group_vars/all.yml`) |
| `common_tasks/reconcile_cm_cms_after_autotls.yml` | MGMT TLS truststore + CMS restart after **27** when Labs `cm_service` already deployed |
| `common_tasks/restart_cm_management_service_api.yml` | POST `/cm/service/commands/restart` + bounded command wait |
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
