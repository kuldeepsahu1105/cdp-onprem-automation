# Agent learnings (crux)

Scan this before deep-diving playbooks/Jenkins. Details: `ansible-playbooks/docs/RUN_ORDER.md`, `REFERENCE.md`, `RUNBOOK.md`.

## Reference examples: [cloudera-labs](https://github.com/cloudera-labs) on GitHub

When implementing or extending **deployment portal**, **Caddy**, **Jenkins**, **Ansible**, **Terraform**, or **CDP/CM** automation in this repo, **look at existing [cloudera-labs](https://github.com/cloudera-labs) org repos for patterns before inventing new ones.** This project already pins some of that stack (for example `cloudera.cluster` in `ansible-playbooks/requirements.yml`).

| Repo | Why it matters here |
|------|---------------------|
| [cloudera-labs/cloudera.cluster](https://github.com/cloudera-labs/cloudera.cluster) | Ansible collection for Cloudera Manager / cluster lifecycle — used directly by this repo (`devel` branch). |
| [cloudera-labs/cloudera-ce-aws](https://github.com/cloudera-labs/cloudera-ce-aws) | Terraform + Ansible on AWS, reverse HTTPS proxies, `group_vars` / playbooks layout — close cousin to PVC ops + portal access patterns. |
| [cloudera-labs/cloudera.exe](https://github.com/cloudera-labs/cloudera.exe) | Opinionated deployment utilities; includes a **Caddy** role and host prep patterns ([docs](https://cloudera-labs.github.io/cloudera.exe/)). |

Also useful: [cloudera-deploy](https://github.com/cloudera-labs/cloudera-deploy) (ansible-navigator quickstarts), [cldr-runner](https://github.com/cloudera-labs/cldr-runner) (execution environments). Search the org: https://github.com/orgs/cloudera-labs/repositories

**User rule (memorise):** Always refer to **cloudera-labs** on GitHub for examples when adding portal/Caddy/Jenkins/Ansible behavior.

## Architecture

- **Jenkins outside VPC:** `detect_ansible_control_reachability` → `ansible_control_reachability: public`. Never `uri`/CM/portal checks via `172.31.x` from the controller; delegate CM API discovery to **cldr-mngr** (`select_cm_api_probe_host`: `127.0.0.1`, then **ansible_host** (public), then FQDN; HTTP and HTTPS — Auto-TLS may answer only on `:7183`). Set `cm_api_url` client host from the discovered address for localhost plays. VPN/bare-metal controller → `private`.
- **Pipeline order:** PREREQS → **PORTAL (10)** → identity → CM → TLS → CDH → monitoring → ECS. Numbered playbooks **10–35** per `ansible-playbooks/docs/RUN_ORDER.md`.
- **Portal before CM:** Caddy CM vhost **502 is expected** until CM is up. URL verify is **milestone-scoped** (portal + IPA at bootstrap; **cm** only after CM install / phase 3 refresh; **pgadmin** only when you add that milestone). Re-running Jenkins **PORTAL** (`10_setup`) still runs Tier A portal + IPA checks — it does **not** probe pgAdmin or CM vhosts unless those milestones are in the play/extra-vars.

## Expected URL verify warnings (PORTAL vs after CM)

On **PORTAL** bootstrap or rerun (`deployment_portal_verify_milestones`: `portal`, `ipa`), Ansible **requires** Caddy on `127.0.0.1:8088` and portal/IPA vhosts only. **pgAdmin** and **Cloudera Manager** Caddy vhost and Tier B external probes are **skipped** until milestones `pgadmin` or `cm` (pvc_setup adds `cm` starting at phase 3). Tier C hairpin and Tier B external checks may still **warn** when Jenkins cannot reach public URLs (SG/CIDR) — that is not a cluster failure if Tier A passed. After **CM_INSTALL**, refresh passes `…,cm` and CM vhost **502** should clear once CM listens on 7180.

## Alignment with cloudera-labs openshift

Reference: cloudera-labs/openshift (cloudera.exe) Caddy + `cloudera.cluster` playbooks. Scope here: portal/Caddy/CM `frontend_url`/`proxy_host` naming — not a full CDH/ECS module migration.

| Labs pattern | Our implementation | Gap / action |
|--------------|-------------------|--------------|
| `proxy_host` = `cm.<reverse_proxy_public_ip_dashed>.pvc.cloudera-labs.com`; Caddy on reverse proxy **:80** | `cm.<dashed-ip>.pvc.cloudera-labs.com` on ops Docker Caddy **:8088** (`caddy_vhost_urls.j2`) | Port **8088** is intentional (SG/docs); hostname shape matches. |
| Install CM Caddy only when CM `uri` status **-1** (unreachable at edge) | PORTAL stage always deploys Caddy; CM vhost **502** until CM is up | Acceptable for Jenkins order; milestone verify gates CM vhost. |
| CM Caddy upstream **HTTP :7180**, then after Auto-TLS **HTTPS :7183** | `deployment_portal_Caddyfile_vhosts.inc.j2` switches on `autotls_enabled` | Aligned when `autotls_enabled` is set after `27_setup_cm_autotls.yml` + portal refresh. |
| `cloudera.cluster.cm*` **`module_defaults`**: `host=proxy_host`, `port=80` | CDH/ECS plays still use direct `cm_host` + `cm_api_port`; **`apply_cm_caddy_load_balancer.yml`** uses Caddy vhost + `deployment_portal_http_port` when `cm_config_api_via_caddy_proxy: auto` | Documented; scoped proxy for `frontend_url` apply only (not full collection rewrite). |
| `frontend_url` via `cm_config` to **`https://proxy_host`** (play after proxy) | `http://cm.<slug>.<base>:8088` via `apply_cm_caddy_load_balancer.yml` after `build_deployment_portal_facts` | Labs HTTPS on :443; we use HTTP on **8088** unless `cm_external_url` overrides. |
| FreeIPA Caddy **`freeipa.<ip>...`**, `redir / /ipa/ui`, HTTP upstream + **Referer** | Vhost key **`ipa`**; **`redir / /ipa/modern-ui/`** (default landing); proxy **`/ipa/modern-ui/`** and **`/ipa/ui`**; Referer matches request path | Labs still document legacy-only redirect; we prefer modern UI while keeping legacy URL. |
| pgAdmin **`pgadmin.<ip>...`** → host **:5050** or dedicated role | Caddy → `cldr-portal-pgadmin:80`; host maps **5050** (`deployment_portal_pgadmin_host_port`) | See open PRs on pgAdmin email/healthcheck; URL shape aligned. |
| Deployment summary index: cm, freeipa, pgadmin, knox, ecs | `deployment_portal_index.html.j2` tiles: CM, IPA, pgAdmin, ECS, monitoring | **Knox** vhost not on Caddy; link via base cluster / Knox gateway FQDN only. |
| ECS **`*.apps.ecs.<ip>...`** wildcard → ECS master **:80** | Single **`ecs.<ip>...`** vhost → `console.<ecs_app_domain>:443` | Wildcard app ingress not proxied on ops Caddy; `apps_wildcard` hint in portal context only. |
| Knox **`knox.<ip>...`** Caddy vhost | Not implemented | Future: add `knox` to `caddy_vhost_service_names` + vhost block when Knox URL known. |

## Portal / Caddy

- Listen **8088**; smoke: `http://<ops-public-ip>:8088/`. Vhost FQDN: `portal.<dashed-public-ip>.pvc.cloudera-labs.com` (dashes, not dots in IP segment).
- Hairpin from the same ops host is optional — warn, do not fail the pipeline on it alone.
- **IPA dual UI:** FreeIPA serves **modern** (`/ipa/modern-ui/`) and **legacy** (`/ipa/ui`) on the server FQDN. Caddy vhost `ipa.<dashed-ops-ip>.pvc.cloudera-labs.com:8088` uses **`@ipa_root` + `redir /ipa/modern-ui/ 301`** (path-only `Location`, avoids malformed `http:host:port`); `reverse_proxy` HTTP to `<ipaserver-fqdn>` with `header_up Host`, path-matched **Referer**, **X-Forwarded-Host/Proto**, and **`handle_response`** rewriting upstream `Location` from IPA FQDN back to the Caddy vhost (openshift / ipa-rewrite pattern; not HTTPS upstream to :443). On **ipaserver**, `zz-ipa-caddy-proxy.conf` + relaxed `ipa-rewrite` HTTPS redirect for HTTP from Caddy. Portal index links both UIs (`target=_blank`). Tier A verifies `/`, `/ipa/modern-ui/`, and `/ipa/ui` on the Caddy vhost (`follow_redirects=no` — **301 is success**). **CM** block: upstream **`deployment_portal_cm_upstream_host`** (cldr-mngr `private_ip`) + `header_up Host` = CM FQDN; HTTP vs HTTPS + `transport` per autotls mode; **`handle_response`** rewrites upstream `Location` from CM FQDN/:7183 to `cm.*:8088`. Post-CM: CM API **`frontend_url`** → Caddy CM vhost (`apply_cm_caddy_load_balancer.yml` calls `cm_config` via Caddy vhost port **8088**, trim/sanitize `cm_host_name`); facts **`cm_caddy_public_url`**, **`ecs_caddy_console_url`** from `caddy_vhost_urls.j2` (no trailing slash). Direct `:7180`/`:7183` curl may 301 to CM FQDN — browsers use Caddy. Tier A / portal CM probe: **`probe_cm_manager_ui_http.yml`** when `127.0.0.1:7180` is closed.
- **pgAdmin:** Caddy upstream must use compose service name **`pgadmin:80`** (not `container_name` — wrong DNS → **502**). Publish **`0.0.0.0:5050:80`** when SG allows direct UI. **`PGADMIN_DEFAULT_EMAIL`** must use a real TLD — pgAdmin 8 rejects `.local` (e.g. `admin@cldrsetup.local` from `admin@{{ cluster_domain }}`). Default **`pgadmin_default_email`**: `admin@{{ caddy_vhost_public_base }}` (`admin@pvc.cloudera-labs.com`). After upgrading Caddyfile/compose, re-run **PORTAL** or `docker compose up -d --force-recreate pgadmin caddy` in `deployment_portal_config_dir`. `verify_deployment_portal_pgadmin.yml` fails PORTAL with `docker logs` if the container is down. Optional `deployment_portal_pgadmin_debug_logs: true` dumps logs on success. Tier B from Jenkins: GET `http://<ops-public-ip>:8088/` with **`Host: pgadmin.<slug>.<base>`** — not only `:5050`.
- **RHEL:** remove `podman-docker` before installing `docker-ce` (conflicts with Docker CE).
- **Monitoring:** Grafana/Prometheus/Alertmanager are **not** published on host ports — only **Caddy :8088** (vhost `grafana.<dashed-ip>.pvc.cloudera-labs.com` or path `/grafana/`). Caddy upstreams: Compose service names `grafana` / `prometheus` / `alertmanager` on `deployment_portal`. **cAdvisor** direct **:8089**. Jenkins **PORTAL** still passes `-e monitoring_stack_enabled=false` so playbook **32** is not implied — but **`detect_deployment_portal_monitoring`** (localhost) + **`detect_deployment_portal_monitoring_on_host`** (before sync) set **`deployment_portal_monitoring_routes_enabled`**, which Caddy/index use (extra-vars cannot override this fact). **PORTAL-only** refresh therefore restores Grafana/Prometheus/cAdvisor tiles and Caddy vhosts when containers already run on ipaserver. Portal context **`monitoring.enabled`** matches that flag. Run **32** / Jenkins **MONITORING** to install or upgrade the stack. Milestone **`monitoring`** verifies `/grafana/login` and `/prometheus/-/healthy` on localhost.

## Ansible pitfalls

- **Never** multiple `set_fact` keys in one task when values reference sibling keys (`_acr_*`, `_portal_*`, etc.) — split tasks or use explicit `hostvars` / `deployment_portal_context`.
- **`when:` lists** with Jinja `in` on items: use `intersect` filter or quote the full expression — bare YAML breaks parsing.
- **`detect_ansible_control_reachability`:** probes/`set_fact` for control mode → **`delegate_to: localhost`** (env vars, not remote host). **Tier B** builds `deployment_tier_b_url_checks` on localhost — read via `hostvars['localhost']`; `_tier_b_run_any` is true under Jenkins (`BUILD_NUMBER` / `JENKINS_URL`) when probes exist.
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
