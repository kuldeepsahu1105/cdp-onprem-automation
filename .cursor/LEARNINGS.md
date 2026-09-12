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

- **Jenkins outside VPC:** `detect_ansible_control_reachability` → `ansible_control_reachability: public` (`ANSIBLE_CONTROL_VIA_JENKINS=1`, `jenkins_override.yml`). Never `uri`/CM/portal checks via `172.31.x` from the controller. **CM API probes run on the controller** against `ansible_host` (HTTPS `:7183` first), not delegated loopback on cldr-mngr when the manager cannot reach its own public EIP. Optional Caddy: `http://cm.<dashed-ip>.pvc.cloudera-labs.com:81/api/version` when `cm_config_api_via_caddy_proxy`. In-VPC localhost plays still delegate to **cldr-mngr** (`select_cm_api_probe_host`: private IP, `ansible_host`, FQDN, then `127.0.0.1`). VPN/bare-metal controller → `private`.
- **CM API `/api/version` reachability:** `curl -k https://<cm-public-ip>:7183/api/version` with **no credentials** often returns **401 Unauthorized** — treat that as **reachable** (scm-server is listening). Ansible `uri` probes for discovery/Caddy vhost checks use `status_code: [200, 301, 303, 401, 403]`; authenticated version fetch still requires **200** for the API version string.
- **CM UI hostname `cm.<dashed-ops-ip>.pvc.cloudera-labs.com` is Caddy-only:** use **`http://…:81`** (portal listener). **`https://cm.<slug>.<base>:7183` will not work** — nothing listens on 7183 on that DNS name. Direct CM HTTPS is **`https://<cldr-mngr-fqdn-or-public-ip>:7183`** (VPC/SG), not the Caddy vhost hostname on CM ports.
- **Pipeline order:** PREREQS → **PORTAL (10)** → identity → CM → TLS → CDH → monitoring → ECS. Numbered playbooks **10–35** per `ansible-playbooks/docs/RUN_ORDER.md`.
- **Portal before CM:** Caddy serves portal/pgAdmin/monitoring/IPA only — **not** CM or ECS. URL verify is **milestone-scoped** (portal + IPA at bootstrap; **cm** milestone verifies direct CM on cldr-mngr, not Caddy). Re-running Jenkins **PORTAL** (`10_setup`) runs Tier A portal + IPA checks unless other milestones are passed.

## Expected URL verify warnings (PORTAL vs after CM)

On **PORTAL** bootstrap or rerun (`deployment_portal_verify_milestones`: `portal`, `ipa`), Ansible **requires** Caddy on `127.0.0.1:<deployment_portal_http_port> (default 81)` and portal/IPA vhosts only. **pgAdmin** and **Cloudera Manager** Caddy vhost and Tier B external probes are **skipped** until milestones `pgadmin` or `cm` (pvc_setup adds `cm` starting at phase 3). Tier B external checks may still **warn** when Jenkins cannot reach public URLs (SG/CIDR) — that is not a cluster failure if Tier A passed. After **CM_INSTALL**, refresh passes `…,cm` and CM vhost **502** should clear once CM listens on 7180.

## Alignment with cloudera-labs openshift

Reference: cloudera-labs/openshift (cloudera.exe) Caddy + `cloudera.cluster` playbooks. Scope here: portal/Caddy/CM `frontend_url`/`proxy_host` naming — not a full CDH/ECS module migration.

| Labs pattern | Our implementation | Gap / action |
|--------------|-------------------|--------------|
| Labs CM Caddy `proxy_host` + `reverse_proxy` to **:7180** / **:7183** | **Not implemented** — CM/ECS use direct manager/console URLs | Portal Caddy **:81** is portal, pgAdmin, monitoring, IPA only (`caddy_vhost_urls.j2`). |
| `frontend_url` via `cm_config` to proxy host | **Not set via Caddy** — optional `cm_external_url` in facts only | Jenkins/API use direct `cm_host` + `cm_api_port`. |
| `cloudera.cluster.cm*` **`module_defaults`**: `host=proxy_host`, `port=80` | All plays use direct `cm_host` + `cm_api_port` (`:7180`/`:7183`) | No Caddy CM API proxy in this repo. |
| FreeIPA Caddy **`freeipa.<ip>...`**, `redir / /ipa/ui`, HTTP upstream + **Referer** | Vhost key **`ipa`**; **`redir / /ipa/modern-ui/`** (default landing); proxy **`/ipa/modern-ui/`** and **`/ipa/ui`**; Referer matches request path | Labs still document legacy-only redirect; we prefer modern UI while keeping legacy URL. |
| pgAdmin **`pgadmin.<ip>...`** → host **:5050** or dedicated role | Caddy → `cldr-portal-pgadmin:80`; host maps **5050** (`deployment_portal_pgadmin_host_port`) | See open PRs on pgAdmin email/healthcheck; URL shape aligned. |
| Deployment summary index: cm, freeipa, pgadmin, knox, ecs | `deployment_portal_index.html.j2` tiles: CM, IPA, pgAdmin, ECS, monitoring | **Knox** vhost not on Caddy; link via base cluster / Knox gateway FQDN only. |
| ECS **`*.apps.ecs.<ip>...`** wildcard → ECS master **:80** | **No ECS Caddy vhost** — `https://console.<ecs_app_domain>` in portal/index | Wildcard app ingress not proxied on ops Caddy; `apps_wildcard` hint in portal context only. |
| Knox **`knox.<ip>...`** Caddy vhost | Not implemented | Future: add `knox` to `caddy_vhost_service_names` + vhost block when Knox URL known. |

## Portal / Caddy

- **Caddy edge port** `deployment_portal_http_port` (default **81**) on ops — hostnames `portal.*`, `pgadmin.*`, `grafana.*`, `ipa.*`, etc. **CM and ECS are not on Caddy** — use `https://cldr-mngr.<domain>:7183` and `https://console.<ecs_app_domain>`.
- Caddy/portal stack runs when **`deployment_portal_enabled`** + **`caddy_vhost_enabled`** — `deployment_portal_caddy_effective` in `resolve_deployment_portal_caddy_enabled.yml` (not `monitoring_stack_enabled`).
- Smoke: `http://<ops-public-ip>:81/`. Vhost FQDN: `portal.<dashed-public-ip>.pvc.cloudera-labs.com` (dashes, not dots in IP segment).
- **IPA dual UI:** FreeIPA serves **modern** (`/ipa/modern-ui/`) and **legacy** (`/ipa/ui`) on the server FQDN. Caddy vhost `ipa.<dashed-ops-ip>.pvc.cloudera-labs.com:81` uses **`@ipa_root` + `redir /ipa/modern-ui/ 301`** (path-only `Location`, avoids malformed `http:host:port`); `reverse_proxy` HTTP to `<ipaserver-fqdn>` with `header_up Host`, path-matched **Referer**, **X-Forwarded-Host/Proto**, and **`handle_response`** rewriting upstream `Location` from IPA FQDN back to the Caddy vhost (openshift / ipa-rewrite pattern; not HTTPS upstream to :443). On **ipaserver**, `zz-ipa-caddy-proxy.conf` + relaxed `ipa-rewrite` HTTPS redirect for HTTP from Caddy. Portal index links both UIs (`target=_blank`). Tier A verifies `/`, `/ipa/modern-ui/`, and `/ipa/ui` on the Caddy vhost (`follow_redirects=no` — **301 is success**). CM Tier A uses **`probe_cm_manager_ui_http.yml`** on cldr-mngr (manager IP/FQDN `:7180`/`:7183`), not Caddy.
- **pgAdmin:** Caddy upstream must use compose service name **`pgadmin:80`** (not `container_name` — wrong DNS → **502**). Publish **`0.0.0.0:5050:80`** when SG allows direct UI. **`PGADMIN_DEFAULT_EMAIL`** must use a real TLD — pgAdmin 8 rejects `.local` (e.g. `admin@cldrsetup.local` from `admin@{{ cluster_domain }}`). Default **`pgadmin_default_email`**: `admin@{{ caddy_vhost_public_base }}` (`admin@pvc.cloudera-labs.com`). After upgrading Caddyfile/compose, re-run **PORTAL** or `docker compose up -d --force-recreate pgadmin caddy` in `deployment_portal_config_dir`. `verify_deployment_portal_pgadmin.yml` fails PORTAL with `docker logs` if the container is down. Optional `deployment_portal_pgadmin_debug_logs: true` dumps logs on success. Tier B from Jenkins: GET `http://<ops-public-ip>:81/` with **`Host: pgadmin.<slug>.<base>`** — not only `:5050`.
- **RHEL:** remove `podman-docker` before installing `docker-ce` (conflicts with Docker CE).
- **Monitoring:** Grafana/Prometheus/Alertmanager publish on host ports **and** Caddy **:81** vhosts when enabled. **`detect_deployment_portal_monitoring_on_host`** sets **`deployment_portal_monitoring_routes_enabled`** when containers exist even if **`monitoring_stack_enabled`** was false. Do **not** tie **`deployment_portal_caddy_effective`** to `monitoring_stack_enabled` — that made Jenkins **PORTAL** a no-op when `pvc_setup.sh` passed `-e monitoring_stack_enabled=false`. **PORTAL** sets **`deployment_portal_install_required`**; compose/Caddy/pgAdmin/monitoring containers are **force-recreated only when rendered templates change** (`sync_deployment_portal_content.yml`). Run **32** / Jenkins **MONITORING** for a dedicated monitoring-only phase after portal bootstrap.

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
