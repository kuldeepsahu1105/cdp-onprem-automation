# Ansible variable contracts (portal verify & CM API)

Cross-playbook facts and import order for deployment portal URL verification and Cloudera Manager API probes. **Read this before editing** `verify_*.yml`, `detect_ansible_control_reachability.yml`, `resolve_cm_connect_host.yml`, or portal sync tasks.

Automated checks: `jenkins/scripts/validate-ansible-contracts.sh` (runs from Jenkins `validate-prereqs.sh` after YAML parse).

---

## Playbook import order (portal verify chain)

End-to-end order inside `sync_deployment_portal_content.yml` (used by `10_setup_deployment_portal.yml` and `35_refresh_deployment_portal.yml`):

| Step | Task file | Purpose |
|------|-----------|---------|
| 1 | `deployment_portal_load_host_facts.yml` (playbook, before sync) | Copy `deployment_portal_context`, `caddy_vhost_urls`, anchor/IPA/CM FQDNs from `hostvars['localhost']` onto ops host |
| 2 | `sync_deployment_portal_content.yml` | Render templates, `docker compose up`, optional monitoring re-sync |
| 3 | `verify_deployment_portal_caddy.yml` | Container + localhost index, then URL tiers |
| 3a | → `detect_ansible_control_reachability.yml` | `_acr_*` inputs; publishes `ansible_control_reach_public_only` on **localhost** (CM probes skipped via `ansible_control_reachability_skip_cm_probes`) |
| 3b | → `resolve_deployment_portal_verify_milestones.yml` | `_portal_verify_milestones_effective`, `deployment_portal_verify_milestones_effective` on localhost |
| 3c | → `verify_deployment_portal_urls.yml` | Tier A printed URLs + Caddy vhost checks (scoped by milestones) |
| 3d | → `verify_service_urls_from_controller.yml` | Tier B from controller when milestones non-empty |

**Playbook-level prerequisites**

- **`10_setup_deployment_portal.yml` / `35_refresh_deployment_portal.yml` play 1 (localhost):** `build_deployment_portal_facts.yml` must run first — sets `deployment_portal_context`, `deployment_portal_anchor_inv`, `caddy_vhost_urls`, `deployment_portal_host_group_effective`, etc. on localhost.
- **Play 2 (ops host):** `deployment_portal_load_host_facts.yml` before any verify — ops host does not rebuild context locally.
- **`deployment_portal_verify_milestones`:** play vars on `10_setup` default `[portal, ipa]`; refresh play sets `deployment_portal_verify_post_cm: true` so empty milestone list becomes `[portal, ipa, cm]`.

Standalone external verify (no sync): `verify_deployment_portal_external_from_controller.yml` runs milestones resolve + Tier B only.

---

## Portal verify: required facts before `verify_deployment_portal_urls.yml`

| Fact | Set by | Notes |
|------|--------|-------|
| `deployment_portal_context` | `build_deployment_portal_facts.yml` (localhost) → `deployment_portal_load_host_facts.yml` (ops) | `access.primary/external/vpc`, `ops_host`, portal URLs |
| `deployment_portal_anchor_inv` | `build_deployment_portal_facts.yml` (localhost); verify falls back via `hostvars['localhost'].deployment_portal_anchor_inv` | Inventory name of ops/Caddy anchor host |
| `_portal_verify_milestones_effective` | `resolve_deployment_portal_verify_milestones.yml` | Must run immediately before verify URLs (also imported from `verify_deployment_portal_caddy.yml`) |
| `caddy_vhost_urls` | `build_deployment_portal_facts.yml` | Required for Caddy vhost Tier A checks |
| `ansible_control_reach_public_only` | `detect_ansible_control_reachability.yml` (delegate localhost) | Used for optional printed URL / hairpin behavior; read via `hostvars['localhost']` on ops host |
| `deployment_portal_has_ipa`, `deployment_portal_ipa_fqdn`, `deployment_portal_cm_fqdn` | `build_deployment_portal_facts.yml` + load on ops | Milestone-gated checks |
| Group defaults | `group_vars/all.yml` | e.g. `deployment_portal_http_port`, `deployment_portal_url_verify_status_codes`, `caddy_vhost_enabled` |

**Internal `_portal_*` facts:** defined in earlier tasks within `verify_deployment_portal_urls.yml` itself — do not combine dependent keys in a **single** `set_fact` task (Ansible key order is undefined). See comment at top of that file.

**hostvars localhost:** anchor and reachability facts are authoritative on localhost even when verify runs on the ops host; prefer `hostvars['localhost'].…` for control-plane profile facts.

---

## CM API chain: before `set_cm_api_url.yml` / CM URI tasks

Import order in `set_cm_api_url.yml`:

1. `validate_inventory_groups.yml` (`cldr-mngr` present)
2. **`resolve_cm_connect_host.yml`**
   - Sets `cm_host_public`, `cm_host_private`, `cm_host_fqdn`, `cm_manager_host_inv`
   - **`detect_ansible_control_reachability.yml`** (full CM port probes unless skipped)
   - Sets `cm_connect_host`, `cm_api_client_host`, `cm_api_probe_host`, `cm_api_probe_delegate_to`, `cm_host`
   - Uses `ansible_control_reach_public_only` from reachability detect
3. `ensure_cm_admin_password.yml`
4. HTTP/HTTPS probes → `cm_protocol`, `cm_api_port`, **`cm_api_url`**, `cm_api_url_delegated`

| Fact | Set by |
|------|--------|
| `ansible_control_reachability_effective`, `ansible_control_reach_public_only` | `detect_ansible_control_reachability.yml` (localhost) |
| `_acr_*` | Same file; transient inputs — do not use in `when:` across other task files |
| `cm_api_connect_host` | Optional override in `group_vars/all.yml` |
| `cm_manager_inventory_host` | `group_vars/all.yml` (default `cldr-mngr` host) |

**Consumers:** `25_verify_cm.yml` → `verify_cm_tiered_urls.yml` (imports `set_cm_api_url.yml` and Tier B controller verify). Portal Caddy verify uses detect with **`ansible_control_reachability_skip_cm_probes: true`** and explicit `cm_host_public` / `cm_host_private` vars — do not assume CM API facts exist on the ops host play.

---

## Editing checklist

1. Run `./jenkins/scripts/validate-ansible-contracts.sh` locally (needs `python3`).
2. If you add a `_portal_*`, `_acr_*`, or `deployment_portal_*` condition in `verify_*.yml`, ensure a setter exists (task `set_fact`, play vars, or `group_vars/all.yml`) and document it here.
3. Split `set_fact` tasks when one new key’s value references another key defined in the **same** task.
4. After logic changes, run `ansible-playbook --syntax-check` on affected numbered playbooks (Jenkins `ANSIBLE_SYNTAX`).

See also: `docs/RUNBOOK.md` (URL verification tiers), `docs/REFERENCE.md` (group_vars tables).
