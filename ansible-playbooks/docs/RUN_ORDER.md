# Playbook run order

Numbered playbooks **10–35** follow **deployment work order** (same sequence as `pvc_setup.sh` and Jenkins). Each number is unique; router playbooks import sub-playbooks with higher numbers in the same phase (for example `11_identity_setup.yml` imports `12`–`19`).

Always follow **`pvc_setup.sh`** / **Jenkins** stage order for production runs.

## Jenkins / `pvc_setup.sh` sequence

| Order | Jenkins stage | `DEPLOY_PHASE` | Playbooks (in run order) |
|------:|-----------------|----------------|---------------------------|
| 1 | VALIDATE | — | (outside Ansible) |
| 2 | TERRAFORM | — | inventory generation |
| 3 | PREREQS | `1` / `prereq` | SSH: `00_setup_ssh_preqs` → `01`–`09` (`00` only on PREREQS / `all`; override with `ANSIBLE_RUN_SSH_PREQS`) |
| 4 | PORTAL | `portal` | `10_setup_deployment_portal` |
| 5 | IDENTITY | `2` / `identity` | `00_detect_identity` → `11_identity_setup` |
| 6 | CM_INSTALL | `3` / `cm` | `20`/`22` → `23`–`24` → `25`–`26` (CM API/UI direct on cldr-mngr `:7180`/`:7183`; no Caddy) |
| 7 | CM_TLS_KRB_LDAP | `cm_tls` | `27`–`30` (requires `04_setup_autossh` from PREREQS) |
| 8 | CDH_INSTALL | `cdh` | `31_setup_base_cluster` |
| 9 | MONITORING | `monitoring` | `32_setup_monitoring_stack` (includes portal Caddy/index sync) |
| 10 | ECS_INSTALL | `5` / `ecs` | `33_setup_ecs_cluster` → optional `34_setup_ecs_data_services` |
| — | (manual) | `6` / `portal_refresh` | `35_refresh_deployment_portal` (milestone URL verify / index refresh) |

**Full local flow:** `DEPLOY_PHASE=all ./pvc_setup.sh` = phases 1 → portal (`10`) → identity → CM → cm_tls → CDH → monitoring (if enabled) → ECS.

**Portal refresh:** Bootstrap (`10`) runs only on `DEPLOY_PHASE=portal` (Jenkins **PORTAL**). `35_refresh_deployment_portal.yml` runs on `DEPLOY_PHASE=6` / `portal_refresh`, or when `DEPLOYMENT_PORTAL_REFRESH=true` on other phases. Monitoring stage updates Caddy via `32_setup_monitoring_stack.yml` (no extra `35` unless refresh is requested).

## Sequential index (10–35)

| # | Playbook | Notes |
|---|----------|--------|
| 10 | `10_setup_deployment_portal.yml` | Ops portal bootstrap (Caddy edge `deployment_portal_http_port`, default **81** — portal, pgAdmin, monitoring, IPA; not CM/ECS) |
| 11 | `11_identity_setup.yml` | Identity **router** |
| 12 | `12_setup_freeipa_server.yml` | FreeIPA server (skipped for AD) |
| 13 | `13_update_resolv_conf.yml` | resolv.conf / netplan |
| 14 | `14_setup_dns_records.yml` | FreeIPA DNS (skipped for AD) |
| 15 | `15_update_syscfg_network.yml` | RHEL network sysconfig |
| 16 | `16_setup_identity_client.yml` | FreeIPA or AD client |
| 17 | `17_setup_freeipa_client.yml` | FreeIPA only (manual) |
| 18 | `18_setup_ad_client.yml` | AD only (manual) |
| 19 | `19_setup_wildcard.yml` | `*.apps` wildcard (FreeIPA) |
| 20 | `20_setup_cm_repos.yml` | CM repo **router** |
| 21 | `21_setup_internal_repo.yml` | Internal mirror web server |
| 22 | `22_download_repos.yml` | Archive / mirror content |
| 23 | `23_setup_postgres.yml` | PostgreSQL for CM |
| 24 | `24_start_cm.yml` | CM server + agents |
| 25 | `25_verify_cm.yml` | Verify CM |
| 26 | `26_setup_cm_license.yml` | License / trial |
| 27 | `27_setup_cm_autotls.yml` | Auto-TLS |
| 28 | `28_setup_cm_krbs.yml` | Kerberos |
| 29 | `29_setup_cm_cms.yml` | CMS |
| 30 | `30_setup_cm_ldap.yml` | LDAP |
| 31 | `31_setup_base_cluster.yml` | CDH base cluster |
| 32 | `32_setup_monitoring_stack.yml` | Grafana / Prometheus |
| 33 | `33_setup_ecs_cluster.yml` | ECS cluster |
| 34 | `34_setup_ecs_data_services.yml` | CDW / CDE / CAI (optional) |
| 35 | `35_refresh_deployment_portal.yml` | Portal re-render only |

## Prerequisites (01–09) and helpers

| Playbook | Notes |
|----------|--------|
| `00_setup_ssh_preqs.yml` | First in wrapper |
| `00_ensure_collections.yml` | Imported by numbered playbooks |
| `00_detect_identity.yml` | Before `11_identity_setup` |
| `01`–`09` | OS prerequisites (`04_setup_autossh.yml` in phase 1 after `03_create_etc_hosts`) |
| `99_cleanup.yml` | Teardown |
| `unused_legacy_cm_service_enable.yml` | Unused; prefer `29_setup_cm_cms.yml` |

## Old → new filename map

| Old | New |
|-----|-----|
| `28_setup_deployment_portal.yml` | `10_setup_deployment_portal.yml` |
| `10_identity_setup.yml` | `11_identity_setup.yml` |
| `10_setup_freeipa_server.yml` | `12_setup_freeipa_server.yml` |
| `11_update_resolv_conf.yml` | `13_update_resolv_conf.yml` |
| `12_setup_dns_records.yml` | `14_setup_dns_records.yml` |
| `13_update_syscfg_network.yml` | `15_update_syscfg_network.yml` |
| `14_setup_identity_client.yml` | `16_setup_identity_client.yml` |
| `14_setup_freeipa_client.yml` | `17_setup_freeipa_client.yml` |
| `14_setup_ad_client.yml` | `18_setup_ad_client.yml` |
| `15_setup_wildcard.yml` | `19_setup_wildcard.yml` |
| `16_setup_cm_repos.yml` | `20_setup_cm_repos.yml` |
| `16_setup_internal_repo.yml` | `21_setup_internal_repo.yml` |
| `17_download_repos.yml` | `22_download_repos.yml` |
| `18_setup_postgres.yml` | `23_setup_postgres.yml` |
| `19_start_cm.yml` | `24_start_cm.yml` |
| `20_verify_cm.yml` | `25_verify_cm.yml` |
| `21_setup_cm_license.yml` | `26_setup_cm_license.yml` |
| `22_setup_cm_autotls.yml` | `27_setup_cm_autotls.yml` |
| `23_setup_cm_krbs.yml` | `28_setup_cm_krbs.yml` |
| `24_setup_cm_cms.yml` | `29_setup_cm_cms.yml` |
| `25_setup_cm_ldap.yml` | `30_setup_cm_ldap.yml` |
| `26_setup_base_cluster.yml` | `31_setup_base_cluster.yml` |
| `29_setup_monitoring_stack.yml` | `32_setup_monitoring_stack.yml` |
| `27_setup_ecs_cluster.yml` | `33_setup_ecs_cluster.yml` |
| `30_setup_ecs_data_services.yml` | `34_setup_ecs_data_services.yml` |
| `31_refresh_deployment_portal.yml` | `35_refresh_deployment_portal.yml` |
