# Playbook run order

Numbered playbooks **10–35** follow **deployment work order** (same sequence as `pvc_setup.sh` and Jenkins). Each number is unique — no two playbooks share a numeric prefix; router playbooks import sub-playbooks with higher numbers in the same phase (for example `11_identity_setup.yml` imports `12`–`19`). Playbooks with no fixed position of their own (always-imported libraries, optional/manual troubleshooting helpers) are **unnumbered**: `ensure_collections.yml`, `detect_identity.yml`, `ipa_deep_recovery.yml`, `reconcile_cm_agents.yml` — see [Migration: renumbering duplicate prefixes](#migration-renumbering-duplicate-prefixes-2026-09) below.

Always follow **`pvc_setup.sh`** / **Jenkins** stage order for production runs.

## Jenkins / `pvc_setup.sh` sequence

| Order | Jenkins stage | `DEPLOY_PHASE` | Playbooks (in run order) |
|------:|-----------------|----------------|---------------------------|
| 1 | VALIDATE | — | (outside Ansible) |
| 2 | TERRAFORM | — | inventory generation |
| 3 | PREREQS | `1` / `prereq` | SSH: `00_setup_ssh_preqs` → `01`–`09` (`00` only on PREREQS / `all`; override with `ANSIBLE_RUN_SSH_PREQS`) |
| 4 | PORTAL | `portal` | `10_setup_deployment_portal` |
| 5 | IDENTITY | `2` / `identity` | `11_identity_setup` (imports `detect_identity.yml` as its own first play — `pvc_setup.sh` no longer runs `detect_identity.yml` separately; see [Avoiding duplicate work](#avoiding-duplicate-work-within-a-run)) |
| 6 | CM_INSTALL | `3` / `cm` | `20`/`22` → `23`–`24` → `25`–`26` (CM API/UI direct on cldr-mngr `:7180`/`:7183`; no Caddy) |
| 7 | CM_TLS_KRB_LDAP | `cm_tls` | `27` → `28` → `29` → `30` (requires `04_setup_autossh` from PREREQS) |
| 8 | CDH_INSTALL | `cdh` | `31_setup_base_cluster` |
| 9 | MONITORING | `monitoring` | `32_setup_monitoring_stack` (includes portal Caddy/index sync) |
| 10 | ECS_INSTALL | `5` / `ecs` | `33_setup_ecs_cluster` → optional `34_setup_ecs_data_services` |
| 11 | STARTSTOP_AUTOMATION | — | `37_run_ipaserver_ec2_startstop.yml` on ipaserver (script installed by `36` / IDENTITY phase) |
| 12 | DESTROY_STACK | `destroy_stack` | optional `99_cleanup.yml` → `clone_and_run_terraform_destroy.sh` (`DESTROY_STACK_CONFIRM`) |
| — | (manual) | `6` / `portal_refresh` | `35_refresh_deployment_portal` (milestone URL verify / index refresh) |

**Full local flow:** `DEPLOY_PHASE=all ./pvc_setup.sh` = phases 1 → portal (`10`) → identity → CM → cm_tls → CDH → monitoring (if enabled) → ECS.

**Portal refresh:** Bootstrap (`10`) runs only on `DEPLOY_PHASE=portal` (Jenkins **PORTAL**). `35_refresh_deployment_portal.yml` runs on `DEPLOY_PHASE=6` / `portal_refresh`, or when `DEPLOYMENT_PORTAL_REFRESH=true` on other phases. Monitoring stage updates Caddy via `32_setup_monitoring_stack.yml` (no extra `35` unless refresh is requested) — when refresh **is** requested, running `35` again after `32`/`33`/`34` is deliberate (re-render the index/URLs and re-verify), not a duplicate to remove.

## Mandatory vs optional phases

| `DEPLOY_PHASE` | Required for a working cluster? | Notes |
|----------------|----------------------------------|-------|
| `1` / `prereq` | **Mandatory** — first run only | OS prereqs; `00_setup_ssh_preqs` also gates root SSH mesh needed by `27_setup_cm_autotls` later |
| `portal` | Optional | Skippable entirely with `DEPLOYMENT_PORTAL_ENABLED=false`; still recommended for pgAdmin/monitoring/IPA UI links |
| `2` / `identity` | **Mandatory** | FreeIPA or AD must exist before CM Kerberos/LDAP (`cm_tls` phase) |
| `3` / `cm` | **Mandatory** | CM server/agents/DB — everything after depends on it |
| `cm_tls` | **Mandatory for Kerberos/LDAP-secured clusters**; skippable only for throwaway/manual-TLS clusters | Order inside this phase (`27→28→29→30`) is fixed — do not reorder or split without re-reading `VARIABLE_CONTRACTS.md` |
| `cdh` | **Mandatory** | Base CDH cluster (HDFS/YARN/ZK) |
| `monitoring` | Optional | Gated by `MONITORING_STACK_ENABLED` (default true); safe to skip |
| `5` / `ecs` | Optional | Only when ECS is part of the deployment |
| `6` / `portal_refresh` | Optional, idempotent | Re-render/re-verify portal content; safe to run repeatedly |
| `7` / `dataservices` | Optional | CDW/CDE/CAI on top of ECS |
| `destroy_stack` | Manual only | Never part of `all`/`full` |

Re-running a **mandatory** phase is safe (every numbered playbook is idempotent against live CM/FreeIPA/OS state) but re-running it *unnecessarily inside the same `pvc_setup.sh` invocation* is the waste this doc's [Avoiding duplicate work](#avoiding-duplicate-work-within-a-run) section tracks — prefer running each mandatory phase **once per `pvc_setup.sh` invocation** and let optional refresh phases (`6`, `DEPLOYMENT_PORTAL_REFRESH=true`) handle re-verification.

## Avoiding duplicate work within a run

`pvc_setup.sh` and the numbered playbooks already share several "already done" facts so that combining or re-running steps does not redo expensive work. When adding a new phase or playbook, reuse these instead of introducing a new probe/import that runs unconditionally:

| Mechanism | Scope | Prevents |
|-----------|-------|----------|
| `--skip-tags collections` (set by `pvc_setup.sh run_playbook`) | Across every `ansible-playbook` process in one `pvc_setup.sh` invocation | Re-running `ansible-galaxy collection install` per playbook (collections are ensured once at wrapper start) |
| `ansible_collections_ensured_this_run` (`common_tasks/ensure_ansible_collections.yml`) | Within one `ansible-playbook` process | Router playbooks (`11`, `20`, `37`) that import `ensure_collections.yml` directly *and* import sub-playbooks which import it again — the Galaxy check now runs once per process even when `--skip-tags collections` is not used (standalone runs) |
| `cm_api_context_resolved_this_play` (`common_tasks/resolve_cm_api_probe_context.yml`) | Within one `ansible-playbook` process (persists across plays targeting `localhost`) | Re-running the CM manager reachability + bind-address discovery (`resolve_cm_connect_host.yml` + `select_cm_api_probe_host.yml`) more than once per process |
| `cm_api_url` / `cm_api_version` / `cm_api_discovery_succeeded` early-exit (`common_tasks/set_cm_api_url.yml`) | Within one `ansible-playbook` process | Re-running the `/api/version` HTTP+HTTPS probe loop when a prior play in the **same process** already resolved it (this is why `pvc_setup.sh` runs `25_verify_cm.yml 26_setup_cm_license.yml` as one `ansible-playbook` call — `26` reuses `25`'s already-resolved `cm_api_url`) |
| `11_identity_setup.yml` importing `detect_identity.yml` itself | `pvc_setup.sh` no longer also calls `detect_identity.yml` standalone in `run_phase_2` | A guaranteed double run of the identity-provider assert/debug on every identity-phase run |

**Known, intentional non-dedup (do not "fix"):** `27_setup_cm_autotls.yml`, `28_setup_cm_cms.yml`, `29_setup_cm_ldap.yml`, and `30_setup_cm_krbs.yml` each run as a **separate** `ansible-playbook` process in the `cm_tls` phase (`run_phase_cm_tls`), so each pays its own CM API probe cost — there is no cross-process fact cache (`fact_caching` is disabled in `ansible.cfg`). Combining them into one `run_playbook` call (like `25`+`26`) would remove that cost but also removes independent per-file retry semantics that Jenkins' `DEPLOY_PHASE=cm_tls_krb_ldap` partial-rerun relies on (rerunning only the step that failed) — do not merge these without re-reading `VARIABLE_CONTRACTS.md`'s CM API chain notes and confirming Jenkins partial-rerun behavior is preserved. Likewise, `validate_ansible_ssh_reachability.yml` deliberately re-probes SSH reachability in `00`, `10`, `32`, and `35` even when their target host groups overlap — it is a cheap fail-fast guard against the exact "SSH timeout" symptom in `docs/RUNBOOK.md`, not a redundant check to remove.

## Sequential index (10–35)

| # | Playbook | Notes |
|---|----------|--------|
| 10 | `10_setup_deployment_portal.yml` | Ops portal bootstrap (Caddy edge `deployment_portal_http_port`, default **81** — portal, pgAdmin, monitoring, IPA; not CM/ECS) |
| 11 | `11_identity_setup.yml` | Identity **router** |
| 12 | `12_setup_freeipa_server.yml` | FreeIPA server (skipped for AD) |
| — | `ipa_deep_recovery.yml` | Optional IPA detect/recover/sanitize before **12** (`ipa_server_deep_recovery: true`) |
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
| — | `reconcile_cm_agents.yml` | Optional agent reconcile (also at end of **27**) |
| 26 | `26_setup_cm_license.yml` | License / trial |
| 27 | `27_setup_cm_autotls.yml` | Auto-TLS (+ agent reconcile; CMS trust/restart when MGMT already exists) |
| 28 | `28_setup_cm_cms.yml` | CMS (Cloudera Management Service) — **before LDAP/Kerberos** |
| 29 | `29_setup_cm_ldap.yml` | LDAP (`external_auth` in Labs) |
| 30 | `30_setup_cm_krbs.yml` | Kerberos — **last** in `cm_tls` phase |
| 31 | `31_setup_base_cluster.yml` | CDH base cluster |
| 32 | `32_setup_monitoring_stack.yml` | Grafana / Prometheus |
| 33 | `33_setup_ecs_cluster.yml` | ECS cluster |
| 34 | `34_setup_ecs_data_services.yml` | CDW / CDE / CAI (optional) |
| 35 | `35_refresh_deployment_portal.yml` | Portal re-render only |
| 36 | `36_install_ipaserver_ec2_startstop.yml` | EC2 start/stop script on ipaserver (end of IDENTITY / `pvc_setup` phase 2) |
| 37 | `37_run_ipaserver_ec2_startstop.yml` | Run start/stop/describe via script (Jenkins `STARTSTOP_AUTOMATION`) |

## Prerequisites (01–09) and helpers

| Playbook | Notes |
|----------|--------|
| `00_setup_ssh_preqs.yml` | First in wrapper — the only playbook that still uses prefix `00` |
| `ensure_collections.yml` | Unnumbered — imported by every numbered playbook; no fixed position in the sequence |
| `detect_identity.yml` | Unnumbered — imported by `11_identity_setup.yml` as its first play (no free number between `10` and `11`) — `pvc_setup.sh` does not also invoke it standalone (see [Avoiding duplicate work](#avoiding-duplicate-work-within-a-run)) |
| `01`–`09` | OS prerequisites (`04_setup_autossh.yml` in phase 1 after `03_create_etc_hosts`) |
| `99_cleanup.yml` | Teardown |
| `unused_legacy_cm_service_enable.yml` | Unused; prefer `28_setup_cm_cms.yml` |

## Migration: renumbering duplicate prefixes (2026-09)

Four playbooks previously duplicated a numeric prefix with another, unrelated playbook (`00_*` had three files, `25_*` had two, and `12_*`/`12b_*` used a letter suffix that **sorts before** its own `12_` file under common UTF-8 locales — `ls` in `en_US.UTF-8` prints `12b_ipa_deep_recovery.yml` before `12_setup_freeipa_server.yml`, inverting the intended order). None of the four own a distinct mainline `pvc_setup.sh` sequence slot (they are either always-imported libraries or optional/manual helpers), so they were **de-numbered** rather than assigned a new colliding or ambiguous number. This is a **rename only** — no task/behavior changes, no cascading renumber of any other playbook.

| Old | New | Why |
|-----|-----|-----|
| `00_ensure_collections.yml` | `ensure_collections.yml` | Always-imported Galaxy-collection helper, not a distinct sequence position — duplicated prefix `00` with two unrelated playbooks |
| `00_detect_identity.yml` | `detect_identity.yml` | Identity-phase preamble run immediately before `11_identity_setup.yml`; no free number exists between `10` (portal) and `11` (identity router) — duplicated prefix `00` |
| `12b_ipa_deep_recovery.yml` | `ipa_deep_recovery.yml` | Optional/manual IPA recovery helper, not run by `pvc_setup.sh`/Jenkins by default; letter suffix collided with `12_setup_freeipa_server.yml` and sorted before it in most locales |
| `25_reconcile_cm_agents.yml` | `reconcile_cm_agents.yml` | Optional/manual CM agent reconcile helper, not run by `pvc_setup.sh`/Jenkins by default; duplicated prefix `25` with `25_verify_cm.yml` (the actual mainline step) |

**Compatibility:** All references were updated repo-wide in the same change (`pvc_setup.sh`, docs, `common_tasks/*`, `group_vars/all.yml`). Run `git log --follow -- ansible-playbooks/<new-name>.yml` to see history under the old name. No wrapper stubs were left behind — these four files were never invoked by numeric position from Jenkins or `pvc_setup.sh` argument parsing (only by literal filename), so if you have a fork or downstream script invoking an old filename directly, update it to the new filename above.

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
| `23_setup_cm_krbs.yml` | `30_setup_cm_krbs.yml` |
| `24_setup_cm_cms.yml` | `28_setup_cm_cms.yml` |
| `25_setup_cm_ldap.yml` | `29_setup_cm_ldap.yml` |
| `26_setup_base_cluster.yml` | `31_setup_base_cluster.yml` |
| `29_setup_monitoring_stack.yml` | `32_setup_monitoring_stack.yml` |
| `27_setup_ecs_cluster.yml` | `33_setup_ecs_cluster.yml` |
| `30_setup_ecs_data_services.yml` | `34_setup_ecs_data_services.yml` |
| `31_refresh_deployment_portal.yml` | `35_refresh_deployment_portal.yml` |
| `00_ensure_collections.yml` | `ensure_collections.yml` (2026-09 — see [Migration: renumbering duplicate prefixes](#migration-renumbering-duplicate-prefixes-2026-09)) |
| `00_detect_identity.yml` | `detect_identity.yml` (2026-09) |
| `12b_ipa_deep_recovery.yml` | `ipa_deep_recovery.yml` (2026-09) |
| `25_reconcile_cm_agents.yml` | `reconcile_cm_agents.yml` (2026-09) |
