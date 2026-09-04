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
| `ecs_cluster_name` | `ECS-Cluster` |
| `ecs_deploy_enabled` | `auto` | `auto`, `true`, or `false` — deploy ECS when ecs inventory groups exist |
| `ecs_pvc_ds_version` | `1.5.5-h2000` | CDS repo tag (`1.5.5-h2100` for SP2 CHF1, etc.) |
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
| `scm_csds` | `[]` | CSD JAR URLs (all OS); leave empty on Ubuntu |
| `scm_csds_redhat` | list | CSD JAR URLs for RHEL-based CM (RPM archive paths) |
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
| `16_setup_cm_repos.yml` | both | Router: 16 (internal web) + 17 |
| `16_setup_internal_repo.yml` | internal | Web server on cldr-mngr only |
| `17_download_repos.yml` | both | Mirror (internal) or configure public repo on all hosts |

### OS-specific settings

Package names and paths are in the `os_vars` map:

- `os_vars.RedHat` — RHEL/Rocky/Alma
- `os_vars.Debian` — Ubuntu (Ansible `Debian` OS family)

| `cm_repo_dir` | `/etc/yum.repos.d` (RHEL) or `/etc/apt/sources.list.d` (Ubuntu) | CM repo drop-in directory |
| `cm_repo_file` | `cloudera-manager.repo` or `cloudera-manager.list` | CM repo file name per OS |

On Ubuntu, public mode downloads the official `cloudera-manager.list` from `archive.cloudera.com/p/cm7/<version>/ubuntu2404/apt/` (or `ubuntu2204`, etc.) and imports `archive.key` — matching the Cloudera installation guide.

Access at runtime: `{{ os_vars[ansible_os_family].<key> }}` or `{{ os.<key> }}` after `set_os_facts`.

**PostgreSQL paths:** RHEL stores config in the data directory (`postgres_data_dir`). Ubuntu uses separate paths — config in `postgres_config_dir` (`/etc/postgresql/<version>/main`), data in `postgres_data_dir` (`/var/lib/postgresql/<version>/main`). Playbook `18_setup_postgres.yml` deploys templates to `postgres_config_dir`.

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

### Phase 1 — Infrastructure & prerequisites

| Playbook | Description |
|---|---|
| `00_setup_ssh_preqs.yml` | SSH prerequisites |
| `01_install_collection.yml` | Install Ansible collections on control node (`localhost`); system update on targets |
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
| `10_identity_setup.yml` | Phase 2 router (all of 10–15) |
| `10_setup_freeipa_server.yml` | FreeIPA server (skipped for AD) |
| `11_update_resolv_conf.yml` | DNS (netplan or resolv.conf) |
| `12_setup_dns_records.yml` | FreeIPA DNS records (skipped for AD) |
| `13_update_syscfg_network.yml` | `/etc/sysconfig/network` (RHEL) |
| `14_setup_identity_client.yml` | FreeIPA client or AD realm join |
| `14_setup_ad_client.yml` | AD realm join only |
| `14_setup_freeipa_client.yml` | FreeIPA client only |
| `15_setup_wildcard.yml` | `*.apps` wildcard DNS (FreeIPA only) |

### Phase 3 — Cloudera Manager

| Playbook | Description |
|---|---|
| `16_setup_cm_repos.yml` | **Repo router** — internal web + mirror or public archive config |
| `16_setup_internal_repo.yml` | Internal HTTP repo web server (skipped when `cm_repo_source=public`) |
| `17_download_repos.yml` | Mirror from archive (internal) or configure public `archive.cloudera.com/p/` repos |
| `18_setup_postgres.yml` | PostgreSQL for CM |
| `19_start_cm.yml` | Install/start CM server + agents |
| `20_verify_cm.yml` | Verify CM is running |
| `21_setup_cm_license.yml` | Upload license or trial |
| `22_setup_cm_autotls.yml` | Enable Auto-TLS |
| `23_setup_cm_krbs.yml` | Kerberos (FreeIPA or AD KDC) |
| `25_setup_cm_ldap.yml` | LDAP auth (FreeIPA or AD) |

### Phase 4 — CMS & base cluster

CMS (Management Service) and CDP base cluster are **separate**:

| Playbook | Component | Deploys |
|---|---|---|
| `24_setup_cm_cms.yml` | CMS | Service Monitor, Host Monitor, Event Server, etc. |
| `26_setup_base_cluster.yml` | Base cluster | ZooKeeper, HDFS, YARN |
| `27_setup_ecs_cluster.yml` | ECS cluster | Cloudera Data Services (DOCKER + ECS), embedded control plane |

Requires base cluster for `control_plane.datalake_cluster_name`. Uses `ecs-masters` / `ecs-workers` inventory groups. Skipped when `ecs_deploy_enabled: auto` and ECS groups are empty.

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
| `2` | `identity` | `00_detect_identity`, `10_identity_setup` |
| `3` | `cm` | `16`–`21` |
| `4` | `cluster` | `22`–`27` (ECS skipped if no ecs inventory) |
| `5` | `ecs` | `27_setup_ecs_cluster.yml` |
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
| `common_tasks/install_cloudera_collection.yml` | Galaxy collection install |
| `common_tasks/cleanup/` | Modular cleanup tasks |
