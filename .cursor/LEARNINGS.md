# Agent learnings (crux)

Scan this before deep-diving playbooks/Jenkins. Details: `ansible-playbooks/docs/RUN_ORDER.md`, `REFERENCE.md`, `RUNBOOK.md`.

## Architecture

- **Jenkins outside VPC:** `detect_ansible_control_reachability` → `ansible_control_reachability: public`. Never `uri`/CM/portal checks via `172.31.x` from the controller; delegate CM API discovery to **cldr-mngr** (`select_cm_api_probe_host`: `127.0.0.1`, then **ansible_host** (public), then FQDN; HTTP and HTTPS — Auto-TLS may answer only on `:7183`). Set `cm_api_url` client host from the discovered address for localhost plays. VPN/bare-metal controller → `private`.
- **Pipeline order:** PREREQS → **PORTAL (10)** → identity → CM → TLS → CDH → monitoring → ECS. Numbered playbooks **10–35** per `ansible-playbooks/docs/RUN_ORDER.md`.
- **Portal before CM:** Caddy CM vhost **502 is expected** until CM is up. URL verify is **milestone-scoped** (portal + IPA at bootstrap; CM after refresh / post-CM). **pgAdmin** Caddy vhost is **warn-only** at `portal`/`ipa` milestones; add milestone **`pgadmin`** to hard-fail on pgAdmin vhost.

## Portal / Caddy

- Listen **8088**; smoke: `http://<ops-public-ip>:8088/`. Vhost FQDN: `portal.<dashed-public-ip>.pvc.cloudera-labs.com` (dashes, not dots in IP segment).
- Hairpin from the same ops host is optional — warn, do not fail the pipeline on it alone.
- **IPA** `reverse_proxy`: `header_up Host` = ipaserver FQDN. **CM** block: split HTTP vs HTTPS + `transport` per autotls mode.
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
