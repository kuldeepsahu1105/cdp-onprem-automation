# Agent learnings (crux)

Scan this before deep-diving playbooks/Jenkins. Details: `ansible-playbooks/docs/RUN_ORDER.md`, `REFERENCE.md`, `RUNBOOK.md`.

## Architecture

- **Jenkins outside VPC:** `detect_ansible_control_reachability` → `ansible_control_reachability: public`. Never `uri`/CM/portal checks via `172.31.x` from the controller; delegate CM API discovery to **cldr-mngr** (`select_cm_api_probe_host`: `127.0.0.1`, then **ansible_host** (public), then FQDN; HTTP and HTTPS — Auto-TLS may answer only on `:7183`). Set `cm_api_url` client host from the discovered address for localhost plays. VPN/bare-metal controller → `private`.
- **Pipeline order:** PREREQS → **PORTAL (10)** → identity → CM → TLS → CDH → monitoring → ECS. Numbered playbooks **10–35** per `ansible-playbooks/docs/RUN_ORDER.md`.
- **Portal before CM:** Caddy CM vhost **502 is expected** until CM is up. URL verify is **milestone-scoped** (portal + IPA at bootstrap; CM after refresh / post-CM). **pgAdmin** Caddy vhost is **warn-only** at `portal`/`ipa` milestones; add milestone **`pgadmin`** to hard-fail on pgAdmin vhost.

## Alignment with cloudera-labs openshift

Reference: cloudera-labs/openshift (cloudera.exe) Caddy + `cloudera.cluster` playbooks. Scope here: portal/Caddy/CM `frontend_url`/`proxy_host` naming — not a full CDH/ECS module migration.

| Labs pattern | Our implementation | Gap / action |
|--------------|-------------------|--------------|
| `proxy_host` = `cm.<reverse_proxy_public_ip_dashed>.pvc.cloudera-labs.com`; Caddy on reverse proxy **:80** | `cm.<dashed-ip>.pvc.cloudera-labs.com` on ops Docker Caddy **:8088** (`caddy_vhost_urls.j2`) | Port **8088** is intentional (SG/docs); hostname shape matches. |
| Install CM Caddy only when CM `uri` status **-1** (unreachable at edge) | PORTAL stage always deploys Caddy; CM vhost **502** until CM is up | Acceptable for Jenkins order; milestone verify gates CM vhost. |
| CM Caddy upstream **HTTP :7180**, then after Auto-TLS **HTTPS :7183** | `deployment_portal_Caddyfile_vhosts.inc.j2` switches on `autotls_enabled` | Aligned when `autotls_enabled` is set after `27_setup_cm_autotls.yml` + portal refresh. |
| `cloudera.cluster.cm*` **`module_defaults`**: `host=proxy_host`, `port=80` | CDH/ECS plays still use direct `cm_host` + `cm_api_port`; **`apply_cm_caddy_load_balancer.yml`** uses Caddy vhost + `deployment_portal_http_port` when `cm_config_api_via_caddy_proxy: auto` | Documented; scoped proxy for `frontend_url` apply only (not full collection rewrite). |
| `frontend_url` via `cm_config` to **`https://proxy_host`** (play after proxy) | `http://cm.<slug>.<base>:8088` via `apply_cm_caddy_load_balancer.yml` after `build_deployment_portal_facts` | Labs HTTPS on :443; we use HTTP on **8088** unless `cm_external_url` overrides. |
| FreeIPA Caddy **`freeipa.<ip>...`**, `redir / /ipa/ui`, HTTP upstream + **Referer** | Vhost key **`ipa`** (not `freeipa`); redir + HTTP upstream + Host/Referer in `deployment_portal_Caddyfile_vhosts.inc.j2` | Rename to `freeipa` only if DNS/bookmarks must match labs literally (`caddy_vhost_service_names.ipa`). |
| pgAdmin **`pgadmin.<ip>...`** → host **:5050** or dedicated role | Caddy → `cldr-portal-pgadmin:80`; host maps **5050** (`deployment_portal_pgadmin_host_port`) | See open PRs on pgAdmin email/healthcheck; URL shape aligned. |
| Deployment summary index: cm, freeipa, pgadmin, knox, ecs | `deployment_portal_index.html.j2` tiles: CM, IPA, pgAdmin, ECS, monitoring | **Knox** vhost not on Caddy; link via base cluster / Knox gateway FQDN only. |
| ECS **`*.apps.ecs.<ip>...`** wildcard → ECS master **:80** | Single **`ecs.<ip>...`** vhost → `console.<ecs_app_domain>:443` | Wildcard app ingress not proxied on ops Caddy; `apps_wildcard` hint in portal context only. |
| Knox **`knox.<ip>...`** Caddy vhost | Not implemented | Future: add `knox` to `caddy_vhost_service_names` + vhost block when Knox URL known. |

## Portal / Caddy

- Listen **8088**; smoke: `http://<ops-public-ip>:8088/`. Vhost FQDN: `portal.<dashed-public-ip>.pvc.cloudera-labs.com` (dashes, not dots in IP segment).
- Hairpin from the same ops host is optional — warn, do not fail the pipeline on it alone.
- **IPA** `reverse_proxy`: `header_up Host` = ipaserver FQDN. **CM** block: split HTTP vs HTTPS + `transport` per autotls mode. Post-CM: CM API **`frontend_url`** → Caddy CM vhost (`apply_cm_caddy_load_balancer.yml`); facts **`cm_caddy_public_url`**, **`ecs_caddy_console_url`** from `caddy_vhost_urls.j2`. Tier A / portal CM probe: **`probe_cm_manager_ui_http.yml`** when `127.0.0.1:7180` is closed.
- **RHEL:** remove `podman-docker` before installing `docker-ce` (conflicts with Docker CE).

## Ansible pitfalls

- **Never** multiple `set_fact` keys in one task when values reference sibling keys (`_acr_*`, `_portal_*`, etc.) — split tasks or use explicit `hostvars` / `deployment_portal_context`.
- **`when:` lists** with Jinja `in` on items: use `intersect` filter or quote the full expression — bare YAML breaks parsing.
- **`detect_ansible_control_reachability`:** probes/`set_fact` for control mode → **`delegate_to: localhost`** (env vars, not remote host).
- **Galaxy:** `ansible_install_collections_if_needed.yml`; `00_ensure_collections` import; `pvc_setup.sh` can skip collections tag when already installed.

## Jenkins UI

- **Colors:** `ansiColor` + `JENKINS_ANSI_CONSOLE=1` for Ansible; strip ANSI only for **artifact** log files. `access-urls.txt` stays plain ASCII.
- After **Jenkinsfile** edits: job param **`REFRESH_JENKINSFILE=YES`**. Stage help: text param **`PIPELINE_STAGES_REFERENCE`**.

## Validation gates (run before merge)

```bash
./jenkins/scripts/validate-ansible-yaml.sh    # all common_tasks + playbooks
./jenkins/scripts/validate-ansible-contracts.sh  # set_fact / import heuristics; see VARIABLE_CONTRACTS.md
```

Jenkins: `validate-prereqs.sh` runs YAML parse (+ contracts when wired). **Do not merge** Ansible verify/portal/CM changes without these passing.

## Git / process (agents)

- Touch **verify + portal + CM host resolution** together; read **`ansible-playbooks/docs/VARIABLE_CONTRACTS.md`**.
- Prefer **one PR** with validation over incremental breaks (user pain: half-fixed verify gates).
- Standalone-first rules: see root **`AGENTS.md`**.
