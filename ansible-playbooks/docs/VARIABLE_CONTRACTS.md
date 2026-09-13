# Ansible variable contracts (portal verify & CM API)

Cross-playbook facts and import order for deployment portal URL verification and Cloudera Manager API probes. **Read this before editing** `verify_*.yml`, `detect_ansible_control_reachability.yml`, `resolve_cm_connect_host.yml`, or portal sync tasks. For upstream Ansible/Caddy/portal patterns, see [`.cursor/LEARNINGS.md`](../../.cursor/LEARNINGS.md) (cloudera-labs reference repos).

Automated checks: `jenkins/scripts/validate-ansible-contracts.sh` (runs from Jenkins `validate-prereqs.sh` after YAML parse).

---

## Playbook import order (portal verify chain)

End-to-end order inside `sync_deployment_portal_content.yml` (used by `10_setup_deployment_portal.yml` and `35_refresh_deployment_portal.yml`):

| Step | Task file | Purpose |
|------|-----------|---------|
| 1 | `deployment_portal_load_host_facts.yml` (playbook, before sync) | Copy `deployment_portal_context`, `caddy_vhost_urls`, access profile/URLs, anchor/IPA/CM FQDNs from `hostvars['localhost']` onto ops host |
| 2 | `sync_deployment_portal_content.yml` | Render templates (including `docker-compose.yml` + `.env` per stack), `docker compose up`, optional monitoring re-sync |
| 3 | `verify_deployment_portal_caddy.yml` | Container + localhost index, then URL tiers |
| 3a | → `detect_ansible_control_reachability.yml` | `_acr_*` inputs; publishes `ansible_control_reach_public_only` on **localhost** (CM probes skipped via `ansible_control_reachability_skip_cm_probes`) |
| 3b | → `resolve_deployment_portal_verify_milestones.yml` | `_portal_verify_milestones_effective`, `deployment_portal_verify_milestones_effective` on localhost |
| 3c | → `verify_deployment_portal_urls.yml` | Tier A printed URLs + Caddy vhost checks (scoped by milestones) |
| 3d | *(moved)* | Tier B no longer runs inside `verify_deployment_portal_caddy.yml` on the ops host |
| 4 | `10_setup_deployment_portal.yml` / `35_refresh_deployment_portal.yml` localhost play | `verify_deployment_portal_external_from_controller.yml` → Tier B from Jenkins when milestones non-empty |

**Playbook-level prerequisites**

- **`10_setup_deployment_portal.yml` / `35_refresh_deployment_portal.yml` play 1 (localhost):** `resolve_deployment_portal_host.yml` runs before the Caddy skip gate so play 2 `hosts:` can template `deployment_portal_host_group_effective` even when Caddy is off. `build_deployment_portal_facts.yml` sets `deployment_portal_context`, `deployment_portal_anchor_inv`, `caddy_vhost_urls`, etc. on localhost when the stack runs.
- **Play 2 (ops host):** `deployment_portal_load_host_facts.yml` before any verify — ops host does not rebuild context locally.
- **`deployment_portal_verify_milestones`:** play vars on `10_setup` default `[portal, ipa]`; refresh play sets `deployment_portal_verify_post_cm: true` so empty milestone list becomes `[portal, ipa]`. `resolve_deployment_portal_verify_milestones.yml` always strips `cm` / `cm_tls` — CM URL checks run only in `25_verify_cm.yml`. Tier A/Tier B pgAdmin checks run only when `pgadmin` is in the list.

Standalone external verify (no sync): `verify_deployment_portal_external_from_controller.yml` runs milestones resolve + Tier B only.

---

## Portal verify: required facts before `verify_deployment_portal_urls.yml`

| Fact | Set by | Notes |
|------|--------|-------|
| `deployment_portal_context` | `build_deployment_portal_facts.yml` (localhost) → `deployment_portal_load_host_facts.yml` (ops) | `access.primary/external/vpc`, `ops_host`, portal URLs |
| `deployment_portal_anchor_inv` | `build_deployment_portal_facts.yml` (localhost); verify falls back via `hostvars['localhost'].deployment_portal_anchor_inv` | Inventory name of ops/Caddy anchor host |
| `_portal_verify_milestones_effective` | `resolve_deployment_portal_verify_milestones.yml` | Must run immediately before verify URLs (also imported from `verify_deployment_portal_caddy.yml`) |
| `caddy_vhost_urls` | `build_deployment_portal_facts.yml` | Required for Caddy vhost Tier A checks |
| `ansible_control_reach_public_only` | `detect_ansible_control_reachability.yml` (delegate localhost) | Marks printed portal URLs optional on ops host / Jenkins public profile; read via `hostvars['localhost']` on ops host |
| `deployment_portal_has_ipa`, `deployment_portal_ipa_fqdn`, `deployment_portal_cm_fqdn`, `deployment_portal_cm_upstream_host` | `build_deployment_portal_facts.yml` + load on ops | Index/link facts only; CM UI/API probes are not run from portal verify |
| Group defaults | `group_vars/all.yml` | e.g. `deployment_portal_http_port`, `deployment_portal_url_verify_status_codes`, `caddy_vhost_enabled`, `deployment_portal_basic_auth_enabled` (HTTP auth on `/downloads/*`) |
| `deployment_portal_expose_ssh_keys` | `group_vars/all.yml` | `true` (default): always copy controller SSH keys to `/downloads/ssh/`. `false`: disable. `auto`: export only when `deployment_portal_basic_auth_enabled` is `true` |
| `deployment_portal_ssh_keys_expose_effective` | `build_deployment_portal_operator_access.yml` (+ sync refresh on localhost) | Resolved boolean: `true` when `deployment_portal_expose_ssh_keys` is `true`; when `auto`, matches `deployment_portal_basic_auth_enabled`; when `false`, `false` |
| `deployment_portal_base_master_fqdn`, `deployment_portal_inventory_hosts`, `deployment_portal_ecs_api_cache`, `ipa_caddy_modern_public_url`, `ipa_caddy_legacy_public_url` | `build_deployment_portal_facts.yml` (localhost) → `deployment_portal_load_host_facts.yml` + `deployment_portal_operator_access_facts_from_localhost.yml` | Required by `deployment_portal_operator_access.j2` when play 2 re-renders operator access (sync delegates SSH refresh to localhost but Jinja lookup uses the ops play host namespace) |

**Jenkins:** check out `main` at or after commit `691b943` (portal operator-access `deployment_portal_postgres_fqdn` fix) before running the PORTAL stage; later commits add the remaining operator-access localhost facts above.

**Internal `_portal_*` facts:** defined in earlier tasks within `verify_deployment_portal_urls.yml` itself — do not combine dependent keys in a **single** `set_fact` task (Ansible key order is undefined). See comment at top of that file.

**hostvars localhost:** anchor and reachability facts are authoritative on localhost even when verify runs on the ops host; prefer `hostvars['localhost'].…` for control-plane profile facts.

---

## CM API chain: CM playbooks only (not deployment portal)

**Admin password API reset:** `ensure_cm_admin_password.yml` runs in **`24_start_cm.yml`** (after first server start) and **`27_setup_cm_autotls.yml`** (before Auto-TLS API). It is **not** imported from portal playbooks or from read-only API probes.

**Probe context:** `resolve_cm_api_probe_context.yml` → `resolve_cm_connect_host.yml` + `select_cm_api_probe_host.yml`.

**`set_cm_api_url.yml`:** HTTP/HTTPS `/api/version` probes → `cm_protocol`, `cm_api_port`, **`cm_api_version`**, **`cm_api_url`** (imports probe context only when `cm_api_probe_host` is unset). **`fetch_cm_api_version_slug.yml`:** `GET /api/version` → **`cm_api_version`** slug (`v58`, `v59`, …). Used by **`set_cm_api_url.yml`** and **`wait_for_cm_api.yml`** (re-fetches before each health wait). **`wait_for_cm_api.yml`** then checks `GET {{ cm_api_url }}/cm/version` (same as `25_verify_cm.yml`).

**CM UI:** Cloudera Manager **`frontend_url`** is not set via Caddy. Portal index and Jenkins list **direct** `https://cldr-mngr.<domain>:7183` (or `:7180`). Optional `cm_external_url` in `group_vars` sets `cm_frontend_url_effective` only when you need a custom published URL.

| Fact | Set by |
|------|--------|
| `ansible_control_reachability_effective`, `ansible_control_reach_public_only` | `detect_ansible_control_reachability.yml` (localhost) |
| `_acr_*` | Same file; transient inputs — do not use in `when:` across other task files |
| `cm_api_connect_host` | Optional override in `group_vars/all.yml` |
| `cm_manager_inventory_host` | `group_vars/all.yml` (default `cldr-mngr` host) |
| `cm_frontend_url_effective` | `resolve_caddy_service_public_urls.yml` — optional `cm_external_url` override only |
| `deployment_portal_public_host` | `resolve_caddy_service_public_urls.yml` — Caddy lab hostname for the deployment index (`portal.<ops-ip-dashed>.<base>`) |
| `pgadmin_caddy_public_url` | `resolve_caddy_service_public_urls.yml` — preferred browser URL for pgAdmin on Caddy port `deployment_portal_http_port` (default **81**) |
| `ipa_caddy_public_url`, `ipa_caddy_modern_public_url`, `ipa_caddy_legacy_public_url` | `resolve_caddy_service_public_urls.yml` — FreeIPA Caddy vhost base, modern (`/ipa/modern-ui/`), and legacy (`/ipa/ui`) browser URLs |
| `deployment_tier_b_url_checks` | `build_deployment_tier_b_url_checks.yml` on **localhost** — Tier B reads via `hostvars['localhost']` in `verify_service_urls_from_controller.yml` |
| `ecs_control_plane_url_effective` | `resolve_ecs_control_plane_url.yml` — `ecs_control_plane_url` or `https://console.<ecs_app_domain>` (no Caddy) |

**Consumers:** `25_verify_cm.yml` → `verify_cm_tiered_urls.yml`. Deployment portal playbooks (**10**, **35**) do **not** call CM API or CM UI probes — index links use inventory FQDNs only; live-stats JSON is inventory-only.

---

## Editing checklist

1. Run `./jenkins/scripts/validate-ansible-contracts.sh` locally (needs `python3`).
2. If you add a `_portal_*`, `_acr_*`, or `deployment_portal_*` condition in `verify_*.yml`, ensure a setter exists (task `set_fact`, play vars, or `group_vars/all.yml`) and document it here.
3. Split `set_fact` tasks when one new key’s value references another key defined in the **same** task.
4. After logic changes, run `ansible-playbook --syntax-check` on affected numbered playbooks (Jenkins `ANSIBLE_SYNTAX`).

See also: `docs/RUNBOOK.md` (URL verification tiers), `docs/REFERENCE.md` (group_vars tables).
