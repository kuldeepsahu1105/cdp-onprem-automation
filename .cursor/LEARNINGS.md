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

## Portal / Caddy

- Listen **8088**; smoke: `http://<ops-public-ip>:8088/`. Vhost FQDN: `portal.<dashed-public-ip>.pvc.cloudera-labs.com` (dashes, not dots in IP segment).
- Hairpin from the same ops host is optional — warn, do not fail the pipeline on it alone.
- **IPA** (match [cloudera-labs/openshift](https://github.com/cloudera-labs/openshift) Caddy vhost): `redir / /ipa/ui permanent`; `reverse_proxy http://<ipaserver-fqdn>` with `header_up Host` and `header_up Referer https://<ipaserver-fqdn>/ipa/ui` (not HTTPS upstream to :443). User URL: `http://ipa.<dashed-ops-ip>.pvc.cloudera-labs.com:8088/`. **CM** block: upstream **`deployment_portal_cm_upstream_host`** (cldr-mngr `private_ip`) + `header_up Host` = CM FQDN; HTTP vs HTTPS + `transport` per autotls mode. Post-CM: CM API **`frontend_url`** → Caddy CM vhost (`apply_cm_caddy_load_balancer.yml`, trim/sanitize — stray newlines in `cm_host_name` cause broken redirects like `//n`); facts **`cm_caddy_public_url`**, **`ecs_caddy_console_url`** from `caddy_vhost_urls.j2` (no trailing slash). Tier A / portal CM probe: **`probe_cm_manager_ui_http.yml`** when `127.0.0.1:7180` is closed.
- **pgAdmin:** Caddy upstream must use compose service name **`pgadmin:80`** (not `container_name` — wrong DNS → **502**). Publish **`0.0.0.0:5050:80`** when SG allows direct UI. **`PGADMIN_DEFAULT_EMAIL`** must use a real TLD — pgAdmin 8 rejects `.local` (e.g. `admin@cldrsetup.local` from `admin@{{ cluster_domain }}`). Default **`pgadmin_default_email`**: `admin@{{ caddy_vhost_public_base }}` (`admin@pvc.cloudera-labs.com`). After upgrading Caddyfile/compose, re-run **PORTAL** or `docker compose up -d --force-recreate pgadmin caddy` in `deployment_portal_config_dir`. `verify_deployment_portal_pgadmin.yml` fails PORTAL with `docker logs` if the container is down. Optional `deployment_portal_pgadmin_debug_logs: true` dumps logs on success. Tier B from Jenkins: GET `http://<ops-public-ip>:8088/` with **`Host: pgadmin.<slug>.<base>`** — not only `:5050`.
- **RHEL:** remove `podman-docker` before installing `docker-ce` (conflicts with Docker CE).

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
