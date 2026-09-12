# Playbook run order

Numbered playbooks are **roughly** ordered by deployment phase. Some numbers are reused on purpose: **router** playbooks import **sub-playbooks** that share the same prefix (for example `10_identity_setup.yml` imports `10_setup_freeipa_server.yml`).

Always follow **`pvc_setup.sh`** / **Jenkins** stage order for production runs. Use this table when choosing a single playbook or debugging phase gaps.

## Jenkins / `pvc_setup.sh` sequence

| Order | Jenkins stage | `DEPLOY_PHASE` | Playbooks (in run order) |
|------:|-----------------|----------------|---------------------------|
| 1 | VALIDATE | — | (outside Ansible) |
| 2 | TERRAFORM | — | inventory generation |
| 3 | PREREQS | `1` / `prereq` | SSH: `00_setup_ssh_preqs` → `01`–`09` (see phase 1 below) |
| 4 | PORTAL | `portal` | `28_setup_deployment_portal` (bootstrap; monitoring off in wrapper) |
| 5 | IDENTITY | `2` / `identity` | `00_detect_identity` → `10_identity_setup` → `31_refresh` (via wrapper) |
| 6 | CM_INSTALL | `3` / `cm` | `16_setup_cm_repos` or `17` → `18`–`21` → `31_refresh` |
| 7 | CM_TLS_KRB_LDAP | `cm_tls` | `22_setup_cm_autotls` → `31_refresh` → `23`–`25` → `31_refresh` |
| 8 | CDH_INSTALL | `cdh` | `26_setup_base_cluster` → `31_refresh` |
| 9 | MONITORING | `monitoring` | `29_setup_monitoring_stack` → `31_refresh` |
| 10 | ECS_INSTALL | `5` / `ecs` | `27_setup_ecs_cluster` → `31_refresh` → optional `30_setup_ecs_data_services` |

**Full local flow:** `DEPLOY_PHASE=all ./pvc_setup.sh` runs phases 1 → portal → 2 → 3 → cm_tls → cdh → monitoring (if enabled) → ECS (27 + optional 30).

**Incremental portal URLs:** After bootstrap (`28`), each Ansible phase above calls `31_refresh_deployment_portal.yml` when the portal is enabled (see `_run_deployment_portal_refresh` in `pvc_setup.sh`).

## Phase 1 — Prerequisites (01–09)

| # | Playbook | Notes |
|---|----------|--------|
| — | `00_setup_ssh_preqs.yml` | Always first in wrapper (not numbered) |
| — | `00_ensure_collections.yml` | Imported by every numbered playbook |
| 01 | `01_install_collection.yml` | OS updates + collection |
| 02 | `02_set_hostname.yml` | |
| 03 | `03_create_etc_hosts.yml` | |
| 04 | `04_setup_autossh.yml` | Optional manual |
| 05 | `05_disable_selinux.yml` | |
| 06–08 | `06`–`08` prereq playbooks | |
| 09 | `09_verify_os_prereqs.yml` | |

## Phase 2 — Identity (10–15)

| # | Playbook | Run via |
|---|----------|---------|
| — | `00_detect_identity.yml` | `10_identity_setup` or phase 2 wrapper |
| **10** | `10_identity_setup.yml` | **Router** — full phase 2 |
| **10** | `10_setup_freeipa_server.yml` | Sub-playbook (FreeIPA only) |
| 11 | `11_update_resolv_conf.yml` | Sub-playbook |
| 12 | `12_setup_dns_records.yml` | Sub-playbook (FreeIPA) |
| 13 | `13_update_syscfg_network.yml` | Sub-playbook |
| **14** | `14_setup_identity_client.yml` | **Router** — FreeIPA or AD client |
| **14** | `14_setup_freeipa_client.yml` | Sub-playbook (FreeIPA only) |
| **14** | `14_setup_ad_client.yml` | Sub-playbook (AD only) |
| 15 | `15_setup_wildcard.yml` | Sub-playbook (FreeIPA) |

## Phase 3 — Cloudera Manager (16–21)

| # | Playbook | Run via |
|---|----------|---------|
| **16** | `16_setup_cm_repos.yml` | **Router** — internal mirror path |
| **16** | `16_setup_internal_repo.yml` | Sub-playbook when `cm_repo_source=internal` |
| 17 | `17_download_repos.yml` | Public or mirror content |
| 18–21 | `18`–`21` | Postgres, CM start, verify, license |

## Phase 4 — TLS, CMS, CDH, portal, monitoring, ECS (22–31)

| # | Playbook | Typical order |
|---|----------|----------------|
| 22 | `22_setup_cm_autotls.yml` | First in `cm_tls` phase |
| 23–25 | Kerberos, CMS, LDAP | After Auto-TLS |
| 24 | `24_setup_cm_cms.yml` | Cloudera Management Service |
| 26 | `26_setup_base_cluster.yml` | CDH base cluster |
| 27 | `27_setup_ecs_cluster.yml` | ECS (after base cluster) |
| 28 | `28_setup_deployment_portal.yml` | Bootstrap ops stack (early in Jenkins when PORTAL stage runs) |
| 29 | `29_setup_monitoring_stack.yml` | After portal network exists |
| 30 | `30_setup_ecs_data_services.yml` | Optional CDW/CDE/CAI |
| 31 | `31_refresh_deployment_portal.yml` | Re-render index/Caddy only |

## Duplicate numbers (intentional)

| Prefix | Router / primary | Sub-playbooks (same prefix) |
|--------|------------------|-----------------------------|
| 10 | `10_identity_setup.yml` | `10_setup_freeipa_server.yml` |
| 14 | `14_setup_identity_client.yml` | `14_setup_freeipa_client.yml`, `14_setup_ad_client.yml` |
| 16 | `16_setup_cm_repos.yml` | `16_setup_internal_repo.yml` |

Do **not** run sub-playbooks alone unless you know the skip conditions; use the router or `pvc_setup.sh`.

## Renamed / unused files

| Old name | New name | Notes |
|----------|----------|--------|
| `22_setup_cm_service.yml` | `unused_legacy_cm_service_enable.yml` | Orphan duplicate of partial CMS enable logic; use `24_setup_cm_cms.yml` instead. Not referenced by Jenkins or `pvc_setup.sh`. |

## Other entry points

| Playbook | Purpose |
|----------|---------|
| `copy_idrsa.yml`, `copy_ranger_hive_ca.yml` | Ad hoc helpers |
| `99_cleanup.yml` | Teardown (requires confirm vars) |
