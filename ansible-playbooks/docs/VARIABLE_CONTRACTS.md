# Ansible variable contracts (portal verify & CM API)

Cross-playbook facts and import order for deployment portal URL verification and Cloudera Manager API probes. **Read this before editing** `verify_*.yml`, `detect_ansible_control_reachability.yml`, `resolve_cm_connect_host.yml`, or portal sync tasks. For upstream Ansible/Caddy/portal patterns, see [`.cursor/LEARNINGS.md`](../../.cursor/LEARNINGS.md) (cloudera-labs reference repos).

Automated checks: `jenkins/scripts/validate-ansible-contracts.sh` (runs from Jenkins `validate-prereqs.sh` after YAML parse).

---

## Playbook import order (portal verify chain)

End-to-end order inside `sync_deployment_portal_content.yml` (used by `10_setup_deployment_portal.yml` and `35_refresh_deployment_portal.yml`):

| Step | Task file | Purpose |
|------|-----------|---------|
| 1 | `deployment_portal_load_host_facts.yml` (playbook, before sync) | Copy `deployment_portal_context`, `caddy_vhost_urls`, access profile/URLs, anchor/IPA/CM FQDNs from `hostvars['localhost']` onto ops host |
| 2 | `sync_deployment_portal_content.yml` | Render templates (including `docker-compose.yml` + `.env` per stack), `manage_ipa_httpd_caddy_proxy_on_ipaserver.yml` on **`[ipaserver]`** when IPA present (apply or remove per **`deployment_portal_ipa_httpd_proxy_enabled`**, default **false**), `docker compose up`, optional monitoring re-sync |
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
| `deployment_portal_has_ipa`, `deployment_portal_ipa_fqdn`, `deployment_portal_ipa_upstream_host`, `deployment_portal_cm_fqdn`, `deployment_portal_cm_upstream_host` | `build_deployment_portal_facts.yml` + load on ops | IPA Caddy connects to the inventory IP (`private_ip`, then `ansible_host`) while sending `deployment_portal_ipa_fqdn` as the upstream `Host`; CM UI/API probes are not run from portal verify |
| Group defaults | `group_vars/all.yml` | e.g. `deployment_portal_http_port`, `deployment_portal_ipa_httpd_proxy_enabled` (default **false** — Caddy-only IPA UI), `ipa_httpd_disable_browser_krb_negotiate` (default **true** — no browser SPNEGO on `/ipa`), `deployment_portal_url_verify_status_codes`, `caddy_vhost_enabled`, `deployment_portal_basic_auth_enabled` (revocable session auth on `/downloads/*`) |
| `deployment_portal_expose_ssh_keys` | `group_vars/all.yml` | `true` (default) or legacy `auto`: request controller SSH key export; export occurs only when `deployment_portal_basic_auth_enabled` is `true`. `false`: disable |
| `deployment_portal_ssh_keys_expose_effective` | `build_deployment_portal_operator_access.yml` (+ sync refresh on localhost) | Resolved boolean: requested SSH key export **and** portal authentication enabled; private keys are never copied into public downloads |
| `deployment_portal_base_master_fqdn`, `deployment_portal_inventory_hosts`, `deployment_portal_ecs_api_cache`, `ipa_caddy_modern_public_url`, `ipa_caddy_legacy_public_url` | `build_deployment_portal_facts.yml` (localhost) → `deployment_portal_load_host_facts.yml` + `deployment_portal_operator_access_facts_from_localhost.yml` | Required by `deployment_portal_operator_access.j2` when play 2 re-renders operator access (sync delegates SSH refresh to localhost but Jinja lookup uses the ops play host namespace) |

**Jenkins:** check out `main` at or after commit `691b943` (portal operator-access `deployment_portal_postgres_fqdn` fix) before running the PORTAL stage; later commits add the remaining operator-access localhost facts above.

**Internal `_portal_*` facts:** defined in earlier tasks within `verify_deployment_portal_urls.yml` itself — do not combine dependent keys in a **single** `set_fact` task (Ansible key order is undefined). See comment at top of that file.

**hostvars localhost:** anchor and reachability facts are authoritative on localhost even when verify runs on the ops host; prefer `hostvars['localhost'].…` for control-plane profile facts.

---

## CM API chain: CM playbooks only (not deployment portal)

**Admin password API reset:** `ensure_cm_admin_password.yml` runs in **`24_start_cm.yml`** (after first server start) and **`27_setup_cm_autotls.yml`** (before Auto-TLS API). It is **not** imported from portal playbooks or from read-only API probes.

**Probe context:** `resolve_cm_api_probe_context.yml` → **`resolve_cm_api_transport.yml`** (`cm_api_use_https`, `cm_api_probe_https_first`, default `cm_api_port`) → `resolve_cm_connect_host.yml` + `select_cm_api_probe_host.yml`. Plays **25–26** default **`cm_api_use_https: false`** (HTTP **:7180**); set **`cm_autotls_complete: true`** or **`cm_api_use_https: true`** after **27** or for HTTPS-only re-runs.

**`set_cm_api_url.yml`:** HTTP/HTTPS `/api/version` probes → `cm_protocol`, `cm_api_port`; **`assemble_cm_api_url.yml`** (+ **`resolve_cm_api_url_host.yml`**) → **`cm_api_version`**, **`cm_api_url`** (imports probe context only when `cm_api_probe_host` is unset). URL assembly runs when probes run **or** stored URL/version is missing/invalid (discovery-only skips must not skip assembly). **`fetch_cm_api_version_slug.yml`:** `GET /api/version` → **`cm_api_version`** slug (`v58`, `v59`, …). Used by **`assemble_cm_api_url.yml`** and **`wait_for_cm_api.yml`** (re-fetches before each health wait). **`wait_for_cm_api.yml`** then checks `GET {{ cm_api_url }}/cm/version` (same as `25_verify_cm.yml`). **`fetch_cm_autotls_api_state.yml`** → **`cm_tls_mode`**, **`cm_api_https_active`**, **`cm_autotls_api_enabled`**, **`cm_agent_use_tls`**, **`cm_autotls_config_flags_unreported`** (generateCmca + agent truststore when `/cm/config` omits flags); prints via **`print_cm_tls_status.yml`** (used from **25**, **27** / `print_cm_urls.yml`, agent reconcile). **27** re-fetches after generateCmca / CM restart before **`print_cm_urls.yml`**.

**`27_setup_cm_autotls.yml` generateCmca gate:** captures **`cm_autotls_setup_intent`** from inventory **`autotls_enabled`** (default **`true`** in `group_vars/all.yml`) before **`set_cm_api_url.yml`** (HTTPS probes may also set runtime `autotls_enabled`). After **`fetch_cm_autotls_api_state.yml`** and agent truststore **`stat`**, sets **`cm_autotls_generate_cmca_skip`** (requires **`not cm_autotls_force_run`** when API+truststore complete) and **`cm_autotls_noop_this_run`** (full skip: one debug line, no generateCmca/restart/agent/CMS plays). Manual HTTPS on **`cm_https_port`** with **`autotls_enabled: false`** still skips generateCmca via **`cm_api_https_on_cm_port`**. On successful **`generateCmca`**, **`apply_cm_restart_after_config.yml`** uses **`realign_cm_api_url_after_autotls_restart.yml`** (HTTPS URL rebuild + **`wait_for_cm_api.yml`**, not full **`set_cm_api_url.yml`** probe chain unless **`cm_api_url`** / slug missing). Manager-agent restart after scm-server restart is gated by **`cm_scm_server_restart_manager_agent`** (`auto` = Auto-TLS runs only; Kerberos/LDAP scm-server restarts skip manager agent unless `always`). **`assert_cm_api_healthy_for_agent_reconcile.yml`** reuses the same realign path and skips when **`cm_api_health_ok`** is already true after restart. When **`cm_restart_after_autotls_this_run`** or **`autotls_applied_this_run`**, localhost sets **`cm_agent_mandatory_restart_after_autotls_this_run`**; cluster agent restarts run via **`reconcile_cm_agents.yml`** when **`cm_agent_reconcile_after_autotls`** (default true). The **`mandatory_restart_cm_agent_after_autotls.yml`** play runs only when **`cm_agent_reconcile_after_autotls: false`**. Agent reconcile sets **`cm_agents_restarted_after_autotls_this_run`** on localhost after the mandatory wave (when used) so **`restart_cm_agent_if_needed.yml`** does not mass-restart again in the same run. Removed duplicate post-restart verify play that re-imported **`resolve_cm_api_probe_context.yml`** / **`set_cm_api_url.yml`**.

**`28_setup_cm_cms.yml` / `configure_cm_cms_autotls_trust.yml`:** same **`cm_autotls_setup_intent`** capture before **`set_cm_api_url.yml`**. **`cms_autotls_trust_required`** is true when **`cm_cms_configure_autotls_trust`** and (**`cm_autotls_api_enabled`** from CM config **or** setup intent with agent **`cm-auto-global_truststore.jks`** on the CM host). Manual TLS (`autotls_enabled: false` in inventory) stays skipped when CM reports HTTPS without Auto-TLS and no agent truststore.

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

**SSH target vs CM API target are separate facts — do not conflate them.** `ansible_control_reachability_effective` / `cm_connect_host` / `cm_api_client_host` pick the address used for CM API `uri`/`wait_for` probes. Jenkins inventory regeneration uses `INVENTORY_SSH_MODE=bastion`: `ipa-node` is reached on its public IP and all other SSH targets use private IPs through `ansible_ssh_common_args` ProxyJump. Direct `generate_inventory.sh` usage defaults to public SSH targets; IPAServer or another cluster node can use `INVENTORY_SSH_MODE=private`. `common_tasks/validate_ansible_ssh_reachability.yml` is a separate guard and the Jenkins preflight invokes Ansible itself so inventory ProxyJump settings are honored. See `docs/OPERATIONS_GUIDE.md` "Running from any controller" and "Control-plane reachability".

---

## Editing checklist

1. Run `./jenkins/scripts/validate-ansible-contracts.sh` locally (needs `python3`).
2. If you add a `_portal_*`, `_acr_*`, or `deployment_portal_*` condition in `verify_*.yml`, ensure a setter exists (task `set_fact`, play vars, or `group_vars/all.yml`) and document it here.
3. Split `set_fact` tasks when one new key’s value references another key defined in the **same** task.
4. After logic changes, run `ansible-playbook --syntax-check` on affected numbered playbooks (Jenkins `ANSIBLE_SYNTAX`).

See also: `docs/OPERATIONS_GUIDE.md` (URL verification tiers), `docs/REFERENCE.md` (group_vars tables).

---

## FreeIPA client enrollment (playbook 16)

| Fact | Set by | Notes |
|------|--------|-------|
| `ipa_kerberos_ccache_path` | `group_vars/all.yml` | Ansible **`KRB5CCNAME=FILE:…`** for **`ipa`/`kinit`** in automation — not **`default_ccache_name`** in krb5.conf |
| `ipa_httpd_disable_browser_krb_negotiate` | `group_vars/all.yml` (default **`true`**) | **`zz-ipa-disable-browser-krb.conf`** on ipaserver (`SetEnv gssapi-no-negotiate`); play **12** + **manage_ipa_httpd_caddy_proxy_on_ipaserver** |
| `krb5_comment_default_ccache_on_ipaserver` | `group_vars/all.yml` (default **`false`**) | When **`false`**, **ipaserver** keeps active **`default_ccache_name = KEYRING:persistent:%{uid}`**; clients stay commented |
| `krb5_libdefaults_default_ccache_commented_line` | `group_vars/all.yml` | Target commented line on **clients** (`ensure_krb5_default_ccache_commented.yml`) |
| `krb5_conf_default_ccache_adjusted` | `ensure_krb5_default_ccache_commented.yml` | **`true`** when main krb5.conf was edited; gates **`ipactl`** / **SSSD** restart helpers |
| `ipa_client_preflight_enabled` | `group_vars/all.yml` (default **`false`**) | When **`true`**, `join_freeipa_client.yml` imports **`preflight_ipa_client_install.yml`** on hosts without **`/etc/ipa/default.conf`** (hostname **`hostname -f`**, FQDN **`getent ahostsv4`**, **`ipaserver`** **`getent hosts`**). No HTTPS **`/ipa/json`** probe — use RUNBOOK **`zlib.error`** **`curl`** checks on ipaserver misconfig. |
| `ipa_client_has_default_conf`, `ipa_client_has_partial_state` | `detect_ipa_client_install_state.yml` | Gates install, optional uninstall, and preflight import |

---

## PostgreSQL / CM database (standalone host)

| Fact | Set by | Notes |
|------|--------|-------|
| `postgres_inventory_group_resolved` | `group_vars/all.yml` | Auto: `[postgres]` → `[postgresql]` → `[db]` → `cldr-mngr`; pin with `postgres_inventory_group` |
| `postgres_inventory_host` | `group_vars/all.yml` | `groups[postgres_inventory_group_resolved][0]` — `ensure_cm_postgres_databases.yml` delegates all `psql` here (play **24** on `cldr-mngr`, play **29** on `localhost`) |
| `postgres_host_fqdn` | `group_vars/all.yml` | CM/CMS JDBC and Reports Manager probe host |
| `postgres_ensure_cm_db_psql_host` | `group_vars/all.yml` | Optional override (`""` = auto). When set via `-e`, used as `psql -h` on `postgres_inventory_host` (delegated; controller reachability irrelevant). |
| `postgres_ensure_cm_db_psql_host_effective` | `resolve_postgres_ensure_cm_db_psql_host.yml` (localhost) | Auto: `postgres_host_fqdn`, else DB host `private_ip`, else `ansible_host` — aligned with CM JDBC, not `127.0.0.1`. |
| `postgres_db_host_psql_cmd` | `ensure_cm_postgres_databases.yml` | `psql` path on `postgres_inventory_host` — from versioned `/usr/pgsql-<ver>/bin/psql`, `/usr/bin/psql`, or `which psql` after stat; Amazon Linux uses native `postgresql<cap>` (no PGDG); RHEL 8/9 uses PGDG + `postgresql<postgresql_version>`. |
| `_postgres_cm_db_tcp_probe_hosts` | `ensure_postgresql_running.yml` (localhost) | Ordered unique TCP probe list: effective host, `postgres_host_fqdn`, DB `private_ip`, `ansible_host`, then `127.0.0.1` as last resort. |
| `_postgres_cm_db_tcp_host_reachable` | `ensure_postgresql_running.yml` (localhost) | First probe host where `wait_for` reports `state: started`; may realign `postgres_ensure_cm_db_psql_host_effective` for delegated `psql`. |
| `_postgres_systemd_unit` | `ensure_postgresql_running.yml` | First matching systemd unit on `postgres_inventory_host` from `hostvars[...].os.postgres_service` (play **23**), `service_facts`, and `postgresql-<ver>` / `postgresql<ver>` / `postgresql` candidates from `postgres_db_host_psql_probe_versions`. Skips `systemd` when any `_postgres_cm_db_tcp_probe_hosts` entry accepts TCP (`wait_for` `state: started`, not task `failed`). Fails before the long wait when no unit is found. |

Optional inventory: add a dedicated group (e.g. `[postgresql]` with one host) and `cldr_hostname` in host vars; leave `postgres_inventory_group` empty for auto-detect, or set `postgres_inventory_group: postgresql` to pin.
