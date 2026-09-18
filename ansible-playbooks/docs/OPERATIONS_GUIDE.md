# Detailed Operations Guide

Detailed controller, networking, deployment, recovery, and troubleshooting
guide for Cloudera Private Cloud. For the concise deployment path, start with
[RUNBOOK.md](RUNBOOK.md). For accepted values and effects of every
operator-facing setting, use [CONFIGURATION.md](CONFIGURATION.md).

All commands assume you are in the `ansible-playbooks/` directory:

```bash
cd ansible-playbooks
```

## Prerequisites

1. **Ansible collections** — any of these (same `requirements.yml`, idempotent):

| How you run | Collections |
|-------------|-------------|
| **`./pvc_setup.sh`** or repo **`clone_and_run_pvc_automation.sh`** | Installed automatically at start |
| **Jenkins** `run-ansible.sh` | Same as `pvc_setup.sh` per stage (skip when already installed) |
| **Single playbook** | `./run-playbook.sh 10_setup_deployment_portal.yml` **or** `ansible-playbook …` (each playbook imports `ensure_collections.yml`) **or** once manually: `ansible-galaxy collection install -r requirements.yml` |

2. Prepare `inventory.ini` with your hosts (see [REFERENCE.md](REFERENCE.md#inventory-groups)).
3. Configure `group_vars/all.yml` (domain, passwords, AD vars if needed).
4. Place `license.txt` and an SSH private key in `ansible-playbooks/` (or use `~/.ssh/id_rsa`):
   - `*.pem` (e.g. `sshkey.pem` copied from Terraform output)
   - `id_rsa` in `ansible-playbooks/`
   - `~/.ssh/id_rsa` on the control machine
   - Or set `ANSIBLE_PRIVATE_KEY=/path/to/key` before running the wrapper

5. **CM archive credentials** (phase 3 only) — use **one** of:
   - `*info.txt` in `ansible-playbooks/` with `login:` and `password:` lines
   - `CM_INFO_FILE=/path/to/info.txt`
   - `CM_REPO_USERNAME` + `CM_REPO_PASSWORD` environment variables
   - `cm_repo_username` / `cm_repo_password` in `group_vars/all.yml`

   If an info file or env vars are set, the wrapper passes them as Ansible extra vars; you do **not** also need credentials in `all.yml` or manual `-e` flags.

## Control node and OS support

The wrappers and playbooks support:

| Control node | How to run |
|---|---|
| Mac laptop (remote) | `brew install ansible jq`; run from repo root or `ansible-playbooks/` |
| RHEL / Ubuntu laptop (remote) | Install `ansible`, `jq`; run `./clone_and_run_pvc_automation.sh` or `cd ansible-playbooks && ./pvc_setup.sh` |
| Cluster node (`cldr-mngr`, `ipaserver`) | `CONTROL_MODE=local DEPLOY_PHASE=all ./pvc_setup.sh` from `ansible-playbooks/` (uses `~/.ssh/id_rsa` if no PEM in cwd) |

### Control-plane reachability (Jenkins vs VPN / bare metal)

Ansible must pick **public** vs **VPC-private** addresses for CM API `uri` probes and for which portal URLs are required during verify:

| Control node | Typical profile | What to set |
|---|---|---|
| **Jenkins** (or any host **outside** the VPC, no route to `10.x` / `172.31.x`) | `public` | Automatic: `run-ansible.sh` sets `ANSIBLE_CONTROL_VIA_JENKINS=1` and `jenkins_override.yml` sets `ansible_control_reachability: public`. CM API uses `ansible_host` (public IP), not `private_ip`; discovery delegates to `cldr-mngr` at `127.0.0.1`. Portal verify skips VPC-only URL hard-fails. |
| **Bare metal / VPN runner** (targets only on private net, no public IP on hosts) | `private` | Default `auto` probes CM `private_ip` vs public from the controller; prefers private when reachable. Or set `ansible_control_reachability: private` / `deployment_portal_access_profile: private`. |
| **`CONTROL_MODE=local` on `cldr-mngr`** | `private` (CM API still `127.0.0.1` on-manager) | `CONTROL_MODE=local` — do **not** break standalone runs on the CM host. |

Override in `group_vars/all.yml` or Jenkins `ANSIBLE_GROUP_VARS_YAML`: `ansible_control_reachability: public|private|auto`. Legacy keys `ansible_controller_outside_vpc` and `cm_api_prefer_private_ip` remain supported.

**`ansible_control_reachability` only picks the CM API / portal-verify address — it never changes SSH.** SSH always connects to inventory `ansible_host` (`common_tasks/resolve_cm_connect_host.yml` and `detect_ansible_control_reachability.yml` set separate facts — `cm_connect_host`, `cm_api_client_host` — used only for `uri`/`wait_for` CM checks). `ansible_host` must itself be an address the control node can reach:

- **Cloud / Terraform inventory:** `generate_inventory.sh` and Jenkins regeneration use public `ansible_host` values.
- **Scenario B — bare metal** (below): `ansible_host` and `private_ip` are intentionally the **same** private address, because the control node is expected to be co-located on that network (`CONTROL_MODE=local` on `cldr-mngr`, or a VPN/bastion runner with real routing to `10.x`/`172.16-31.x`/`192.168.x`). Running this style of inventory from Jenkins or a laptop **outside** that network cannot work — there is no public address recorded to fall back to.

The CM server restart helper is the sole exception: when Jenkins is marked outside the VPC and IPAServer is present, that helper creates a temporary in-memory target for the CM private IP through IPAServer. This handles public HTTP and SSH reaching different machines without changing the generated inventory or any pre-TLS connection behavior.

`00_setup_ssh_preqs.yml` (first play of every phase that touches real hosts) and `10_setup_deployment_portal.yml`, `32_setup_monitoring_stack.yml`, `35_refresh_deployment_portal.yml` (localhost pre-play, after `resolve_deployment_portal_host.yml`) import `common_tasks/validate_ansible_ssh_reachability.yml` to catch this fast: it probes any VPC-private-looking `ansible_host` in the target group and fails with an actionable message when the controller cannot reach it, instead of hanging on an SSH connection timeout. Options:

- `ansible_ssh_reachability_skip: true` — bypass the check on a controller with genuine private routing (bare metal / VPN / `CONTROL_MODE=local`).
- Add an SSH bastion/ProxyJump instead of exposing a public IP: set `ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q bastion-user@<bastion-host>'"` (or `ANSIBLE_SSH_COMMON_ARGS` env var) in `group_vars/all.yml` — the existing `ansible_ssh_common_args` key (see top of that file) already carries `-o StrictHostKeyChecking=no`; append `ProxyCommand`/`ProxyJump` there rather than introducing a new variable.
- Regenerate a Cloud/Terraform-style inventory (public `ansible_host`) when you need Jenkins/laptop access to a deployment that currently only has private addresses recorded.

### Running from any controller (Jenkins, EC2, bare metal, laptop)

This repo's Ansible layer is controller-agnostic by design (`AGENTS.md` "Standalone-first changes") — the same playbooks run unmodified from Jenkins, a standalone EC2 box, an on-prem bare-metal box, or a laptop. What changes between controllers is **which vars/env you set**, not the playbooks. Use this matrix to pick the right settings before running against RHEL or Ubuntu targets:

| Controller | Route to target `10.x`/`172.16-31.x`/`192.168.x`? | `ansible_host` in inventory | `ansible_control_reachability` | Notes |
|---|---|---|---|---|
| **Jenkins agent** (this repo's pipeline) | No (assumed) | Public IP/EIP for every host | `public` for controller-originated HTTP checks | Inventory is regenerated from Terraform before Ansible. |
| **External EC2** (separate box in/out of the target VPC, no Jenkins) | Depends on VPC peering / same VPC | Public IP if outside the VPC; private IP only if it has real routing (same VPC/subnet or VPC peering + SG) | `auto` (probes both) or set explicitly | Export `ANSIBLE_CONTROL_REMOTE=1` if `auto` misdetects (no `BUILD_NUMBER`/`CI` env hints present) and the box is genuinely outside the VPC. |
| **Bare metal** (on-prem box with real private routing to targets) | Yes | Private IP (matches `private_ip`, per Scenario B) | `private` or `auto` | Set `deployment_environment: baremetal`. If bare metal box is *not* co-located (separate private network, no route), use ProxyJump/bastion instead of trying to reach `10.x` directly. |
| **Mac laptop** | No (typical home/office network) | Public IP/EIP | `public` (or `auto`) | `brew install ansible jq`; run from repo root or `ansible-playbooks/`. See Scenario C below. |
| **Windows laptop** | No (typical) | Public IP/EIP | `public` (or `auto`) | Wrappers use `#!/usr/bin/env bash` — run them from **WSL2** (Ubuntu app from Microsoft Store), not native `cmd`/PowerShell. Inside WSL2: `sudo apt update && sudo apt install -y ansible jq openssh-client`, then treat it exactly like an Ubuntu laptop controller. Keep the SSH private key inside the WSL2 filesystem (or `chmod 600` a Windows-mounted copy) — Windows ACLs on `/mnt/c/...` often make `ssh`/Ansible reject the key's permissions. |
| **RHEL/Ubuntu laptop or workstation** | No (typical) | Public IP/EIP | `public` (or `auto`) | Install `ansible`, `jq` via the distro package manager; run `./clone_and_run_pvc_automation.sh` or `cd ansible-playbooks && ./pvc_setup.sh`. |
| **`CONTROL_MODE=local` on `cldr-mngr`** | Yes (is the target) | Private IP (loopback-reachable) | `private` (CM API stays `127.0.0.1` on-manager) | `CONTROL_MODE=local DEPLOY_PHASE=all ./pvc_setup.sh` from `ansible-playbooks/`; uses `~/.ssh/id_rsa` if no PEM in cwd. |

**When to set what:**

- **Inventory `ansible_host` rule:** if the controller has no real network route to the target's private subnet, `ansible_host` must be the target's **public** address (or a bastion/ProxyJump must be configured). This is independent of `ansible_control_reachability`, which only affects CM API/portal-verify probing — see the callout above. Regenerate with `generate_inventory.sh` / `regenerate-inventory-from-terraform.sh` for public-IP inventories; hand-edit only for bare metal (Scenario B) where `ansible_host == private_ip` is intentional.
- **`ANSIBLE_PRIVATE_KEY`:** set before any standalone run so `ansible-playbook --private-key` and Ansible facts resolve the same key: `export ANSIBLE_PRIVATE_KEY=/path/to/key.pem` (or drop `*.pem`/`id_rsa` into `ansible-playbooks/`, or rely on `~/.ssh/id_rsa`). Wrappers (`pvc_setup.sh`, `clone_and_run_pvc_automation.sh`, Jenkins `run-ansible.sh`) resolve the same env var — see `jenkins/scripts/resolve-ansible-ssh-key.sh`.
- **`ansible_ssh_reachability_skip`:** set `true` only when the controller has genuine private routing to the target subnet that the automatic probe cannot detect (rare — most bare-metal/VPN cases are handled by the `auto`/`private` control-mode heuristics already). From Jenkins, pass it via `ANSIBLE_EXTRA_VARS='ansible_ssh_reachability_skip=true'` (see below) rather than editing `group_vars/all.yml`, so it stays a per-run override.
- **CM Postgres `psql` host (`postgres_ensure_cm_db_psql_host`):** plays **24** / **29** run all `psql` / `wait_for` on `postgres_inventory_host` (never on the controller). Auto resolution is in `resolve_postgres_ensure_cm_db_psql_host.yml` (`postgres_ensure_cm_db_psql_host_effective`):

| Controller profile | Auto `psql -h` on DB host | When to pass `-e postgres_ensure_cm_db_psql_host=…` |
|---|---|---|
| **Any** (external Jenkins, in-VPC, laptop) | `postgres_host_fqdn`, else DB `private_ip`, else `ansible_host` — same as CM JDBC | Optional override when auto pick is wrong (e.g. DNS not ready: `-e postgres_ensure_cm_db_psql_host=<private-ip>`). |

**Why not `127.0.0.1`:** an earlier auto path used loopback when `ansible_control_reach_public_only` was true (external controller). That assumed PostgreSQL listens on localhost; many deployments set `listen_addresses` to the VPC IP or FQDN only (e.g. `172.31.x.x`), so delegated `psql -h 127.0.0.1` failed even though CM JDBC to `postgres_host_fqdn` worked. Controller reachability affects SSH and CM API probing only — delegated `psql` always runs on the DB host and must use an address Postgres actually binds.

CM JDBC and Reports Manager probes still use `postgres_host_fqdn` regardless of this delegated `psql` target.
- **Windows/Mac notes (WSL):** both need a POSIX shell (`bash`) — macOS ships one; Windows needs WSL2. Docker/container-based portal steps run inside the ops **target host** (Linux EC2/bare metal), not the controller, so Windows/Mac controllers only need `ansible`, `jq`, `ssh`, and (for Terraform flows) the AWS CLI — no Docker required locally.
- **Jenkins `ANSIBLE_EXTRA_VARS` for reachability overrides:** `run-ansible.sh` → `scripts/lib/ansible_env.sh` (`ansible_extra_args()`) turns space-separated `key=value` pairs into `-e key=value` flags appended to every `ansible-playbook` invocation for that Jenkins run. Example, when a bare-metal/VPN Jenkins agent has real routing and the probe still misfires:

  ```bash
  export ANSIBLE_EXTRA_VARS='ansible_ssh_reachability_skip=true'
  ```

  Combine multiple overrides space-separated: `ANSIBLE_EXTRA_VARS='ansible_ssh_reachability_skip=true ansible_control_reachability=private'`.

### Service URL verification (portal stack + Cloudera Manager)

Printed URLs live in `CDP_ACCESS_URLS_*` / `jenkins/artifacts/access-urls.txt`.

**Cloudera Manager (`25_verify_cm.yml`):**

- **Play order (license before Auto-TLS):** **`25_verify_cm.yml`** and **`26_setup_cm_license.yml`** run while CM is still on **HTTP `:7180`**. **`27_setup_cm_autotls.yml`** (generateCmca) runs later in **`CM_TLS_KRB_LDAP`** / `cm_tls`. Until Auto-TLS is applied, CM REST probes and parcel-repo `GET/PUT /cm/config` use **`http://<reachable-host>:7180`** (`cm_api_use_https: false` by default in `group_vars/all.yml`). After Auto-TLS, **`realign_cm_api_url_after_autotls_restart.yml`** sets **`cm_api_use_https`** / **`cm_autotls_complete`** and the API base moves to **`:7183`**. Re-verify HTTPS-only CM with `-e cm_api_use_https=true` or `-e cm_autotls_complete=true`.
- **TLS status line:** After `set_cm_api_url.yml`, the play imports `fetch_cm_autotls_api_state.yml` → `print_cm_tls_status.yml` (same as `27_setup_cm_autotls.yml` / `print_cm_urls.yml`). Console shows `CM TLS: https|http|auto_tls (7183 active|http 7180)` and **Auto-TLS configured in CM** from `/cm/config` — not the old `Auto-TLS is enabled: False (API http:7180)` probe-only message when HTTPS UI works.
- **Play 25 does not wait on `:7183`:** Playbook **25** does not import **`wait_for_cm_scm_https_listen.yml`** (no multi-minute block when only **:7180** is up). **`set_cm_api_url.yml`** probes **`/api/version`** on the selected transport. Optional **`cm_verify_wait_scm_https_port: true`** applies only when **`cm_autotls_complete`** or **`cm_api_use_https`** with **`cm_protocol: https`** — not when CM config merely reports Auto-TLS enabled before scm-server listens on **:7183**. Before play **27**, discovery tries **HTTP :7180 first** (`cm_api_probe_https_first: false`).
- **Redundant checks:** Playbooks **24** / **27** / **29** may already wait on CM API or systemd; **`25_verify_cm.yml`** is the single gate for `/cm/version`, CMS summary, clusters list, and `verify_cm_tiered_urls.yml`. Set `cm_verify_skip_redundant_systemd_details: false` to restore full `systemctl status` dump; default **true** skips it when API auth succeeded.
- **Required (manager-local):** HTTP/HTTPS UI on `cldr-mngr` via `probe_cm_manager_ui_http.yml` (private IP / `ansible_host` / FQDN, then loopback) and HTTPS UI when `cm_api_https_active` — **fails** the play if CM is down. CM API setup (`set_cm_api_url.yml`) prints `cm_api_url` and probes from Jenkins with delegation per `#57`.
- **External from controller:** Only when `deployment_portal_enabled: false` **and** `deployment_portal_verify_tier_b_enabled: true` (default **false**). With the portal stack enabled, Tier **B** from `10_setup` / `35_refresh` covers portal/monitoring/IPA/ECS milestones only — **not** CM (CM external checks run in `25_verify_cm.yml` when enabled there).

**Portal / monitoring / IPA / ECS** use the tier labels below on the ops host and Ansible controller:

| Tier | Where it runs | What it checks | On failure |
|---|---|---|---|
| **A (required)** | **Ops host** (`ipaserver`): `http://127.0.0.1:<deployment_portal_http_port>/`, Caddy **Host** vhosts scoped by **`deployment_portal_verify_milestones`** (bootstrap **portal** + **ipa**; **monitoring** / **ecs** / **pgadmin** when listed). **`cm` / `cm_tls` are stripped** — CM UI is verified in `25_verify_cm.yml` only | Local service health | **Fail** the play for milestones in the active list |
| **B (external)** | Ansible **controller** when `ansible_control_reachability_effective` is **`public`** | HTTP GET printed **external** URLs for portal stack services (portal/pgAdmin/Grafana Caddy vhosts, IPA, ECS console) via `verify_service_urls_from_controller.yml` — **not CM** | **`deployment_external_url_verify`** (default **`warn`**) or per-service overrides — `warn`, `fail`, or `skip` |

**When portal verify runs:** After `10_setup_deployment_portal.yml` / `35_refresh_deployment_portal.yml` (`verify_deployment_portal_caddy.yml`). Jenkins **PORTAL** reruns get optional Tier **B** warns for printed URLs when security groups allow; manager-local portal/CM checks are separate as above.

### Portal URL verify milestones (by deploy stage)

| Stage / trigger | `deployment_portal_verify_milestones` (cumulative) | Tier **A** Caddy vhosts / host checks | Tier **B** (controller, when public reach) |
|---|---|---|---|
| **PORTAL** (`10_setup_deployment_portal.yml`) | `portal`, `ipa` | Portal index, portal + IPA vhosts (required when IPA in inventory); **no** pgAdmin or CM Caddy vhost probes | Portal (+ IPA when in list); **no** pgAdmin Tier **B** until milestone `pgadmin` |
| **PORTAL pgAdmin hard gate** (optional refresh) | + `pgadmin` | + pgAdmin Caddy vhost required | + pgAdmin external |
| **IDENTITY** (phase 2 refresh) | + `identity` | Same as PORTAL | + FreeIPA printed / Caddy IPA URLs |
| **CM_INSTALL** | — | — | CM `frontend_url` via `26_setup_cm_license.yml` (direct FQDN); **no** `35_refresh` |
| **CM_TLS** (phase `cm_tls`; no CM URL verify in portal refresh) | (same portal milestones as prior refresh — `pvc_setup.sh` passes `portal,ipa,identity` without `cm`/`cm_tls`) | Portal + IPA vhosts only | CM external URLs: **`25_verify_cm.yml`** |
| **CDH** (phase `cdh` refresh) | + `cdh` | (index refresh; no extra vhosts) | (no new probes) |
| **MONITORING** | + `monitoring` | + Grafana / Prometheus vhosts | + Grafana / Prometheus external |
| **ECS** | + `ecs` | (no Caddy — ECS not on portal stack) | + ECS console / gateway URLs (`console_hint`) |

`pvc_setup.sh` portal refresh milestone strings omit **`cm` / `cm_tls`** (CM verify is playbook **`25_verify_cm.yml`** after CM install). `pvc_setup.sh` runs `35_refresh` when `DEPLOYMENT_PORTAL_REFRESH=true`. Legacy `deployment_portal_verify_post_cm: true` on `35_refresh` implies **`portal`, `ipa`** when milestones are omitted; `resolve_deployment_portal_verify_milestones.yml` always strips **`cm` / `cm_tls`** if passed via `-e`.

Variables:

- `deployment_external_url_verify` — global Tier **B** mode (`warn` \| `fail` \| `skip`; default `warn`; Jenkins sets `warn`)
- `deployment_portal_external_url_verify` — legacy alias when global unset
- `deployment_cm_external_url_verify`, `deployment_grafana_external_url_verify`, … — per-service overrides
- `deployment_service_external_url_verify` — optional map `{ cm: warn, grafana: skip, … }`
- `deployment_portal_verify_milestones` — list or comma string (`portal`, `ipa`, `pgadmin`, `identity`, `cdh`, `monitoring`, `ecs`; **`cm` / `cm_tls` ignored** for portal verify); default `[]` in `group_vars`; bootstrap play sets `portal` + `ipa` (not `pgadmin` — avoids failing PORTAL on pgAdmin 502 while the container is still starting)
- `deployment_portal_url_verify_skip_vpc` — skip hard-fail on VPC-only printed URLs when control is public-only (Jenkins sets `true`)
- `ansible_control_reachability` — must be `public` (or auto → public on Jenkins) for Tier **B**

If Tier **B** warns but Tier **A** passed, open security groups for the relevant ports (**81** (`deployment_portal_http_port`), **5050**, **3000**/**9090**/**9093** (Grafana/Prometheus/Alertmanager host publish), **8089** (cAdvisor), **7180**/**7183**, etc.) from Jenkins/office CIDRs. Grep Ansible logs for `Tier B` or `CDP_ACCESS_URLS_BEGIN`; `jenkins/scripts/build-access-urls.sh` lists URLs for email.

**Docker Compose + `.env` on the ops host:** Ansible renders static `docker-compose.yml` files that reference `${VAR}` placeholders and companion **`.env`** files (from `deployment_portal_docker-compose.env.j2` and `monitoring_docker-compose.env.j2`) with bind-mount paths, published ports, images, and credentials sourced from `group_vars` / vault — secrets are not inlined in compose YAML. Deploy paths: **`{{ deployment_portal_config_dir | default('/opt/cldr-deployment-portal') }}/`** (Caddy + pgAdmin; files `docker-compose.yml`, `.env`, `Caddyfile`, `pgadmin-servers.json`) and **`{{ monitoring_config_dir | default('/opt/cldr-monitoring') }}/`** (monitoring stack). Compose v2 loads `.env` automatically from the directory of the `-f` compose file. **Migration:** existing labs keep running until the next **PORTAL** / **MONITORING** sync; the first run adds `.env`, updates compose, and `--force-recreate`s services when templates change (including password/port updates in `.env` only).

**Caddy still on legacy :8088 in `docker ps`:** compose binds `0.0.0.0:${DEPLOYMENT_PORTAL_HTTP_PORT}` (repo default **81** in `.env` via `deployment_portal_http_port`). An ops host that was provisioned earlier keeps the old publish until compose is re-rendered and Caddy is recreated — `docker compose up -d` alone does not remapping ports. Fix: re-run Jenkins **PORTAL** (play 10/35 re-templates compose/`.env` and `--force-recreate caddy` when the files change) or on **ipaserver**: `cd /opt/cldr-deployment-portal && docker compose up -d --force-recreate caddy`. Confirm with `curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:81/`.

**Monitoring host ports:** Grafana (**`monitoring_grafana_host_port`**, default **3000**), Prometheus (**9090**), Alertmanager (**9093**), and cAdvisor (**8089**) publish on the ops host (`0.0.0.0:PORT` in `docker ps`) for direct browser and Tier **B** access. Caddy on **`deployment_portal_http_port`** (default **81**) still serves path routes (`/grafana/`, …) and lab vhosts when `caddy_vhost_enabled` is true — host publishes are **in addition**, not a replacement. With lab vhosts enabled, the portal index prefers monitoring URLs like **`http://cadvisor.<ops-public-ip-dashed>.<caddy_vhost_public_base>:81/`** (same pattern as Grafana/Prometheus; Caddy reverse-proxies to the `cadvisor` container on **8080**). Example for deployment prefix **`ptgtyv1`** on **ipaserver** (ops public IP `52.221.251.41`): `http://cadvisor.52-221-251-41.pvc.cloudera-labs.com:81/` when `caddy_vhost_dns_mode: embedded_ip`. After changing ports, re-run Jenkins **MONITORING** (play **32**) or `docker compose -f {{ monitoring_config_dir | default('/opt/cldr-monitoring') }}/docker-compose.yml up -d --force-recreate`.

**node_exporter (host metrics):** Playbooks **10** (when `monitoring_stack_enabled`), **32** (`MONITORING_STACK_ENABLED=true ansible-playbook -i inventory.ini 32_setup_monitoring_stack.yml`), and **35** (when monitoring routes are active) import **`enroll_monitoring_exporters.yml`**, which installs `node_exporter` as a systemd service (`common_tasks/install_node_exporter.yml`) on every host in `monitoring_node_exporter_host_groups` (default: `ipaserver`, `cldr-mngr`, `base-masters`, `base-workers`, `ecs-masters`, `ecs-workers`) and appends a `node_exporter` job to `{{ monitoring_config_dir }}/prometheus.yml` with one static target per host at `<private_ip>:{{ monitoring_node_exporter_port }}` (default port **19100**). Port **19100** intentionally leaves the commonly claimed Kubernetes DaemonSet `hostPort: 9100` free on ECS nodes. Targets always use the **private IP** — the Prometheus container runs on the ops host's `deployment_portal`/`monitoring_internal` Docker bridge networks and reaches other cluster hosts over the VPC/private network, not the (possibly Jenkins-only-reachable) public IP. Set `monitoring_node_exporter_enabled: false` to skip installation and drop the scrape job entirely; this does not affect `monitoring_stack_enabled` or the Docker-based Prometheus/Grafana/Alertmanager/cAdvisor stack, and never runs when those are disabled (the render block is still gated by `deployment_portal_monitoring_routes_enabled`). Verify: `systemctl status node_exporter` on any target host, then check **Status → Targets** in the Prometheus UI for `job="node_exporter"`.

**process_exporter (per-process metrics — "process advisor"):** Same enrollment playbook **`enroll_monitoring_exporters.yml`** (imported from **10** when `monitoring_stack_enabled`, **32**, and **35** when monitoring routes are active) — a pinned systemd binary (`common_tasks/install_process_exporter.yml`) on every host in `monitoring_process_exporter_host_groups` (default: same list as `monitoring_node_exporter_host_groups`). Groups processes by cmdline regex (`monitoring_process_exporter_process_names` — `cloudera-scm-server`, `cloudera-scm-agent`, `postgres`, `java`, `docker`, `sshd`, `chronyd`, plus a catch-all grouping everything else by executable name) and exposes `namedprocess_namegroup_*` metrics on port **19256** (`monitoring_process_exporter_port`). Port **19256** leaves conventional process-exporter host port **9256** available to Kubernetes workloads. A `process_exporter` job is appended to `{{ monitoring_config_dir }}/prometheus.yml` when `deployment_portal_process_exporter_targets` is copied from the localhost facts play onto the ops host before render (see `deployment_portal_load_host_facts.yml`). Set `monitoring_process_exporter_enabled: false` to skip installation and drop the scrape job. Verify: `systemctl status process_exporter` on any target host, then check **Status → Targets** in the Prometheus UI for `job="process_exporter"`, or query `topk(10, rate(namedprocess_namegroup_cpu_seconds_total[5m]))` in the Prometheus/Grafana UI.

**Troubleshooting — Prometheus `node_exporter` targets DOWN (`connection refused` on `<private_ip>:19100`):**

| Symptom | Likely cause | Fix |
|--------|----------------|-----|
| All `node_exporter` targets DOWN; no `process_exporter` job | Prometheus was synced (play **10**/**35**) with scrape targets but host exporters were never installed, or `process_exporter` targets were not loaded onto the ops host before `prometheus.yml` render | Re-run Jenkins **MONITORING** (`PIPELINE_STAGES` includes `MONITORING`, `MONITORING_STACK_ENABLED=true`) or `cd ansible-playbooks && MONITORING_STACK_ENABLED=true DEPLOY_PHASE=monitoring ./pvc_setup.sh`. On one target: `sudo systemctl status node_exporter` and `ss -lntp \| grep 19100` (should listen `0.0.0.0:19100`; port `9100` remains available to Kubernetes applications). |
| `node_exporter` DOWN only on **ecs-**\* hosts | **MONITORING** ran before **ECS_INSTALL**; portal refresh updated scrape targets without enrolling new nodes | Re-run **MONITORING** or **35** refresh (enrolls exporters when monitoring routes are enabled) after ECS is in inventory. |
| `node_exporter` job missing entirely | `monitoring_node_exporter_enabled: false` or empty `monitoring_node_exporter_host_groups` / missing `private_ip` in inventory | Check `group_vars/all.yml` and inventory; re-run play **32** after fixing. |
| `process_exporter` job missing while `node_exporter` exists | Stale `prometheus.yml` from before process enrollment, or ops host render without `deployment_portal_process_exporter_targets` | Re-run **MONITORING** or **35** after upgrading to a build that copies process scrape facts in `deployment_portal_load_host_facts.yml`; confirm `/opt/cldr-monitoring/prometheus.yml` contains `job_name: process_exporter`. |

**cAdvisor (container-level metrics):** Already part of the monitoring Docker Compose stack (`monitoring_docker-compose.yml.j2`, service `cadvisor`, image `monitoring_cadvisor_image`) — no separate enable flag; it runs whenever `monitoring_stack_enabled` (or an already-deployed stack) is true. Mounts `/`, `/var/run`, `/sys`, and `/var/lib/docker` read-only from the ops host to report per-container CPU/memory/network/disk-IO for every container on that host (Caddy, pgAdmin, Prometheus, Grafana, Alertmanager, and cAdvisor itself), scraped by Prometheus as the `cadvisor` job (`container_*` metrics, e.g. `container_last_seen`, `container_cpu_usage_seconds_total`). Exposed on host port **`monitoring_cadvisor_host_port`** (default **8089**) and via Caddy `/cadvisor/` (path route) or the `cadvisor.<ip>.<base>` lab vhost when `caddy_vhost_enabled` is true. cAdvisor only sees **containers on the ops host** — it does not report on cluster nodes (CM, base-masters/workers, ECS); use `node_exporter` + `process_exporter` for host/process-level metrics on those.

**Grafana provisioning (datasources + prepopulated dashboard):** Gated by `monitoring_grafana_provisioning_enabled` (default `true`) inside the same `deployment_portal_monitoring_routes_enabled` block as the rest of the stack. Ansible renders `{{ monitoring_config_dir }}/grafana/provisioning/datasources/datasources.yml` (Prometheus datasource, `uid: prometheus`, `isDefault: true`; Alertmanager datasource, `uid: alertmanager`, linked via `jsonData.alertmanagerUid` on the Prometheus datasource so Grafana's alerting UI can show Alertmanager state — this is the Prometheus↔Alertmanager↔Grafana inter-linking) and `{{ monitoring_config_dir }}/grafana/provisioning/dashboards/dashboards.yml` (a `file`-type dashboard provider pointing at `/var/lib/grafana/dashboards`, folder **"Cloudera Monitoring"**). The dashboard JSON itself (`ansible-playbooks/files/grafana_dashboards/cm_cluster_overview.json`, a minimal custom "Cloudera Cluster Overview" — not the full community `node_exporter`/id-**1860** dashboard, kept small on purpose) is copied (not templated) to `{{ monitoring_config_dir }}/grafana/dashboards/` and bind-mounted read-only into the Grafana container. It ships CPU/memory/root-filesystem/network panels from `node_exporter`, top-process CPU/memory tables from `process_exporter`, a container count from cAdvisor, and a firing-alerts count from Alertmanager. All panels reference the datasource by the fixed `uid: prometheus` set above (not Grafana's auto-generated id), so the dashboard loads correctly on a fresh provision with no manual wiring. To import the full community dashboards instead (optional, requires internet/Grafana.com access from the browser): **Dashboards → New → Import**, ids **1860** (Node Exporter Full) and **249** (process-exporter) — pick the **Prometheus** datasource (uid `prometheus`) when prompted. Set `monitoring_grafana_provisioning_enabled: false` to skip provisioning entirely and use a bare Grafana install.

**Prometheus alerting rules + Alertmanager receiver:** Gated by `monitoring_alert_rules_enabled` (default `true`). Ansible renders `{{ monitoring_config_dir }}/rules/alerts.yml` (group `cldr-cluster-basic-alerts`: `InstanceDown` — `up == 0` for `monitoring_alert_instance_down_for`, default **2m**; `HostHighCpuLoad` — CPU busy % above `monitoring_alert_high_cpu_threshold` (default **85**) for `monitoring_alert_high_cpu_for` (default **10m**); `HostHighMemoryUsage` — memory used % above `monitoring_alert_high_mem_threshold` (default **90**) for `monitoring_alert_high_mem_for` (default **10m**)) and Prometheus loads it via `rule_files: [/etc/prometheus/rules/*.yml]`. Alertmanager's `route.group_by` is `monitoring_alertmanager_group_by` (default `[alertname, severity]`); the `default` receiver has **no notification integration configured** out of the box (labs just need alerts visible in the Alertmanager/Grafana UI, not paged) — set `monitoring_alertmanager_receiver_webhook_url` to a real webhook (Slack/Opsgenie relay, etc.) to notify externally; when set, a `webhook_configs` entry with `send_resolved: true` is added to the `default` receiver. Set `monitoring_alert_rules_enabled: false` to skip rule rendering (the empty `{{ monitoring_config_dir }}/rules/` mount stays, which Prometheus tolerates). Verify: **Alerts** tab in the Prometheus UI, or **Status → Rules**; Alertmanager UI **Alerts** tab shows the same firing alerts.

**pgAdmin 502 / :5050 unreachable:** On **ipaserver** (or portal host), `cd {{ deployment_portal_config_dir | default('/opt/cldr-deployment-portal') }}` then `docker ps -a --filter name=cldr-portal-pgadmin` and `curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:5050/`. Caddy must reverse-proxy **`pgadmin:80`** (compose service name). Fix: re-run Jenkins **PORTAL** or `docker compose -f docker-compose.yml up -d --force-recreate pgadmin caddy`. Ansible task `verify_deployment_portal_pgadmin.yml` fails with `docker logs` on error; set `deployment_portal_pgadmin_debug_logs: true` for extra log output after a successful sync.

**pgAdmin image / version banner:** Default **`deployment_portal_pgadmin_image: dpage/pgadmin4:latest`** (current upstream 9.x). Jenkins **PORTAL** runs **`docker compose pull pgadmin`** when **`deployment_portal_pgadmin_pull_on_sync`** is true (default), then recreates the container when a newer image was pulled or `.env`/compose changed. Pin a fixed tag (e.g. `dpage/pgadmin4:9.17`) in group_vars override if you need reproducible digests.

**pgAdmin restart loop / invalid email:** pgAdmin rejects `PGADMIN_DEFAULT_EMAIL` values like `admin@cldrsetup.local` (from `admin@{{ cluster_domain }}`). Set `pgadmin_default_email` to a real TLD (default `admin@pvc.cloudera-labs.com`), re-render compose, then on the portal host: `cd /opt/cldr-deployment-portal && docker compose up -d --force-recreate pgadmin`.

When multiple `*.pem` / `id_rsa` or `*license*` files exist in `ansible-playbooks/`, the wrapper prompts you to choose. Override with `ANSIBLE_PRIVATE_KEY`, `LICENSE_FILE`, or `CM_INFO_FILE`.

### Without wrappers (direct `ansible-playbook`)

Jenkins and `pvc_setup.sh` / `clone_and_run_pvc_automation.sh` are optional. From `ansible-playbooks/`:

```bash
ansible-galaxy collection install -r requirements.yml
export ANSIBLE_PRIVATE_KEY=/path/to/your-key.pem   # or place sshkey.pem / id_rsa in this directory
ansible-playbook -i inventory.ini 00_setup_ssh_preqs.yml --private-key "$ANSIBLE_PRIVATE_KEY"
ansible-playbook -i inventory.ini 27_setup_cm_autotls.yml --private-key "$ANSIBLE_PRIVATE_KEY"
```

Playbooks resolve SSH keys and Auto-TLS material on the **control machine** via `ANSIBLE_PRIVATE_KEY`, files under `ansible-playbooks/`, or `group_vars` (`cm_private_key_path`, `cm_node_sudo_password`). Wrappers only set the same env vars and `--private-key` for convenience.

| Target OS | CM repo mode | Notes |
|---|---|---|
| RHEL 8/9 | `public` or `internal` | Internal mirror: RPM + `createrepo` + CDH parcel |
| Ubuntu 22.04 / 24.04 | `public` or `internal` | Internal mirror: apt `.deb` mirror + CDH parcel; public uses official `cloudera-manager.list` |

**CDH base cluster:** Parcel suffix defaults to `auto` — `jammy`/`noble` on Ubuntu workers, `el8`/`el9` on RHEL. Override with `cdh_parcel_os_suffix: noble` etc.

### Phased deployment (`pvc_setup.sh`)

```bash
DEPLOY_PHASE=1 ./pvc_setup.sh    # prerequisites (00–09)
DEPLOY_PHASE=2 ./pvc_setup.sh    # identity: FreeIPA or AD (auto-detect)
DEPLOY_PHASE=3 ./pvc_setup.sh    # CM install (17/18/19/20/21)
DEPLOY_PHASE=4 ./pvc_setup.sh    # autotls, kerberos, CMS, base cluster, ECS (if inventory has ecs-* groups)
DEPLOY_PHASE=5 ./pvc_setup.sh    # ECS cluster only (27)
DEPLOY_PHASE=all ./pvc_setup.sh  # full flow
```

**Dry run** (preview changes without applying):

```bash
# Ansible — check mode + diff
DRY_RUN=true DEPLOY_PHASE=1 ./pvc_setup.sh
./pvc_setup.sh --dry-run

# Via wrapper
DRY_RUN=true DEPLOY_PHASE=3 ./clone_and_run_pvc_automation.sh

# Terraform — plan only (no apply, no inventory copy)
DRY_RUN=true ./clone_and_run_terraform.sh
```

Set `ANSIBLE_DIFF=false` to omit `--diff` during Ansible dry runs. CM API playbooks (`31`, `33`) may still call Cloudera Manager APIs even in check mode.

Identity is auto-detected: `[ipaserver]` in inventory → FreeIPA; empty ipaserver + `ad_kdc_host` → AD.

---

## Scenario A — AWS deployment with FreeIPA

### 1. Provision infrastructure

From the repo root:

```bash
./clone_and_run_terraform.sh
```

This creates EC2 instances and generates `ansible_inventory.ini`. Copy or symlink it to `ansible-playbooks/inventory.ini`.

### 2. Ensure inventory has ipaserver

```ini
[ipaserver]
ipaserver ansible_host=<public_ip> private_ip=<private_ip> cldr_hostname=ipaserver
```

### Why FreeIPA install fails after lab re-runs (playbook 12)

Playbook **`12_setup_freeipa_server.yml`** (via **`11_identity_setup`**) probes **`ipa --version`** for diagnostics and uses **`detect_ipa_server_install_state.yml`** (**`default.conf`**, partial debris, **`ipactl`** not configured) for the destructive decision. It skips uninstall and **`ipa-server-install`** when IPA is already configured (**`default.conf`**, no partial debris, **`ipactl`** not reporting **IPA is not configured** — **`ipactl`** rc≠0 from stopped services alone does not reinstall). A clean new host proceeds directly to installation without uninstall. A confirmed stale/partial server state with concrete install markers, or **`ipa_server_install_force: true`**, runs **`ipa-server-install --uninstall --unattended`** first (best-effort, non-fatal), then preflight (**`mkdir`** under **`/etc/ipa`** + **`ipa_server_etc_ipa_subdirs`** (e.g. **`/etc/ipa/custodia`**), **`/var/lib/ipa`** + **`ipa_server_var_lib_subdirs`**, **`/var/log/ipa`**, plus hostname/DNS asserts), then **`ipa-server-install --unattended`** with VPC **`--forwarder=`** or **`--no-forwarders`** per **`resolve_ipa_install_dns_forwarders.yml`**. Repeated partial installs can still leave debris; use **`ipa_deep_recovery.yml`** or manual cleanup when uninstall alone is not enough.

**Manual `ipa-server-install` after a failed run (ipaserver, root):** When **`/var/log/ipaserver-install.log`** shows **`install_check`** / **`ipaconf.newConf`** / **`ipachangeconf`** with **`FileNotFoundError: [Errno 2]`** on **`/var/lib/ipa/sysrestore/...`**, **`/var/lib/ipa/sysupgrade/sysupgrade.state`**, **`/etc/ipa/default.conf`**, or **`/etc/ipa/custodia/custodia.conf`** (parent **`/etc/ipa/custodia`** missing), IPA is **not** configured (`ipactl status` → **IPA is not configured** / rc=4). Common causes: **sysrestore** debris after a partial install, or **`rm -rf`** under **`/var/lib/ipa`** / **`/etc/ipa`** that left parents without **`sysupgrade/`** / **`sysrestore/`** / **`custodia/`**. **`bind-utils`** / **`dig`** can work while install still fails — do not retry until paths are cleaned and you use **real** passwords (lab default **`PseTeam@123`**, same as Jenkins **`ipaadmin_password`** / **`common_password`**), not documentation placeholders like **`YOUR_DS_PASSWORD`** / **`YOUR_ADMIN_PASSWORD`**.

**Quick fix (custodia only):** `mkdir -p /etc/ipa/custodia` then re-run **`ipa-server-install`** or playbook **12**.

**One-liner (clean slate + dirs, then re-run install or playbook 12):** `ipactl status || true; rm -rf /var/lib/ipa /etc/ipa /etc/dirsrv/slapd-*; mkdir -p /etc/ipa/custodia /var/log/ipa /var/lib/ipa/{sysupgrade,sysrestore,backup,dnssec}`

```bash
# 1) Confirm broken / partial state
ipactl status
test -f /etc/ipa/default.conf && echo "default.conf present" || echo "no default.conf"
ls -la /var/lib/ipa/sysrestore/ 2>/dev/null || true
tail -n 40 /var/log/ipaserver-install.log

# 2) Unattended uninstall (interactive uninstall defaults to "no")
ipa-server-install --uninstall --unattended || ipa-server-install --uninstall --unattended --force

# 3) If ipactl still reports not configured, remove leftover trees
ipactl status || true
rm -rf /var/lib/ipa /etc/ipa
rm -rf /etc/dirsrv/slapd-*

# 3b) install_check writes default.conf, custodia.conf, sysupgrade.state — parents must exist after rm -rf
mkdir -p /etc/ipa/custodia /var/log/ipa /var/lib/ipa/{sysupgrade,sysrestore,backup,dnssec}

# 4) Fresh install — use lab/Jenkins passwords (default admin + DS: PseTeam@123 unless rotated)
FQDN="$(hostname -f)"   # must match inventory FQDN, e.g. ipaserver.cldrsetup.local
IP="$(hostname -I | awk '{print $1}')"
ipa-server-install --setup-dns --unattended \
  --hostname="${FQDN}" --ip-address="${IP}" \
  --domain=cldrsetup.local --realm=CLDRSETUP.LOCAL \
  --ds-password='PseTeam@123' --admin-password='PseTeam@123' \
  --no-dnssec-validation --no-reverse \
  --forwarder=172.31.0.2
```

For automated debris cleanup before install, run **`ansible-playbook -i inventory.ini ipa_deep_recovery.yml -e ipa_server_deep_recovery=true --limit ipaserver`**, then re-run **`ansible-playbook -i inventory.ini 12_setup_freeipa_server.yml --limit ipaserver`** (vars supply passwords and forwarders).

**IPA DNS forwarders:** Default **`dns_forwarders: no`** uses the **AWS VPC resolver** (`--forwarder=x.y.0.2` from the instance private IP) on EC2 when **`ipa_server_install_use_vpc_dns_forwarder: true`** (default). On bare metal, or when the VPC resolver cannot be computed, install falls back to **`--no-forwarders`**. Force **`--no-forwarders`**: set **`dns_forwarders: no-forwarders`** or **`ipa_server_install_use_vpc_dns_forwarder: false`**. Skipped installs (healthy **`ipactl`** + **`default.conf`**) get **`ipa dnsconfig-mod`** toward the VPC resolver when VPC mode applies.

**Jenkins IDENTITY / playbook 12:** The **Assert AWS VPC DNS forwarder** task runs only when **`ipa_install_dns_use_vpc_forwarder`** is true (after **`resolve_ipa_install_dns_forwarders`** finalize). On AWS with **`dns_forwarders: no`**, **`set_dns_facts`** should log **`Deployment environment: aws`** and a VPC resolver (for example **`172.31.0.2`**) in **`DNS nameservers`**; the **IPA install DNS forwarder mode** line should read **`VPC forwarder …`**, not **`--no-forwarders (fallback)`**. If VPC assert is skipped unexpectedly, check **`effective_deployment_env`** / **`effective_vpc_dns_resolver`** in the log and group vars **`ipa_server_install_use_vpc_dns_forwarder`**. **`ipa-server-install` failures** should print **`stderr`** and **`/var/log/ipaserver-install.log`** tail in the **Fail with ipa-server-install diagnostics** task (passwords are not logged; credentials are passed via environment variables).

**Port 389 / 636 conflict (partial install, `ipactl` rc=4):** Playbook **12** preflight fails before **`ipa-server-install`** when **`ss`** shows **389** or **636** listening while **`ipactl`** reports **IPA is not configured** (leftover **389-ds** / **`dirsrv`** from a failed install). Automation: **`ipa_deep_recovery.yml`** with **`ipa_server_deep_recovery: true`**, then re-run **12**. On **ipaserver as root**:

```bash
ipactl status || true
ss -tlnp | grep -E ':389|:636' || true
systemctl list-units 'dirsrv*' --all
# Stop stale Directory Server instances (instance name from /etc/dirsrv/slapd-*)
systemctl stop 'dirsrv@*' 2>/dev/null || true
systemctl stop dirsrv.target 2>/dev/null || true
pkill -u dirsrv ns-slapd 2>/dev/null || true
ss -tlnp | grep -E ':389|:636' || echo "ports 389/636 free"
# When ipactl still reports not configured, remove partial trees then re-run playbook 12
rm -rf /var/lib/ipa /etc/ipa /etc/dirsrv/slapd-*
mkdir -p /etc/ipa/custodia /var/log/ipa /var/lib/ipa/{sysupgrade,sysrestore,backup,dnssec}
```

If **`ipa-server-install`** fails with **port 389 already in use** in **`ipaserver-install.log`**, use the same steps before retrying.

### 3. Detect identity provider

```bash
ansible-playbook -i inventory.ini detect_identity.yml
```

Expected: `effective identity provider: freeipa`

### 4. Run Phase 1 (prerequisites)

```bash
bash pvc_setup.sh
```

Or run playbooks `00` through `09` individually.

### 5. Run Phase 2 (identity + DNS)

```bash
ansible-playbook -i inventory.ini 11_identity_setup.yml
```

### 6. Run Phase 3 (Cloudera Manager)

```bash
# Public repos (default) — archive.cloudera.com/p/
ansible-playbook -i inventory.ini 22_download_repos.yml \
  -e cm_repo_username="<user>" -e cm_repo_password="<pass>"

# OR internal mirror on cldr-mngr (RHEL: RPM; Ubuntu: apt):
# Set cm_repo_source: internal in group_vars/all.yml, then:
ansible-playbook -i inventory.ini 20_setup_cm_repos.yml \
  -e cm_repo_username="<user>" -e cm_repo_password="<pass>"

ansible-playbook -i inventory.ini 23_setup_postgres.yml
# Atlas/CLO DBs: included in group_vars `databases` (atlas_db_*, clo_db_*); created with other CM DBs in play **23** init SQL.
# Amazon Linux 2023 on cldr-mngr: `ensure_cm_postgres_databases` installs native `postgresql17` client (no PGDG); PostgreSQL server may still be 18 on that host or elsewhere.
# `ensure_cm_postgres_databases` delegates `psql` to `postgres_inventory_host`. Auto `psql -h` is `postgres_host_fqdn`, else DB private_ip, else ansible_host (not loopback — see RUNBOOK CM Postgres psql host). Override: `-e postgres_ensure_cm_db_psql_host=<host>`.
ansible-playbook -i inventory.ini 24_start_cm.yml
ansible-playbook -i inventory.ini 25_verify_cm.yml
ansible-playbook -i inventory.ini 26_setup_cm_license.yml
ansible-playbook -i inventory.ini 27_setup_cm_autotls.yml
# CM API probes: VPC private_ip from Jenkins (not same-host public EIP); manager IP/FQDN on cldr-mngr. SG must allow 7180/7183 from Jenkins to private IPs.
ansible-playbook -i inventory.ini 28_setup_cm_cms.yml
ansible-playbook -i inventory.ini 29_setup_cm_ldap.yml
ansible-playbook -i inventory.ini 30_setup_cm_krbs.yml
```

**Manual KDC account-manager import (CM API):** After `/cm/config` is set, POST credentials (use HTTPS `:7183` when Auto-TLS is on): `curl -sk -u admin:'<cm_admin_pass>' -X POST 'https://<cldr-mngr-fqdn>:7183/api/v59/cm/commands/importAdminCredentials?username=<principal-urlencoded>&password=<password-urlencoded>'` — then restart `cloudera-scm-server` and confirm `ImportCredentials` in `/var/log/cloudera-scm-server/cloudera-scm-server.log`.

**Kerberos encryption types (AES):** Defaults use **AES only** (`krb5_enc_types`: `aes256-cts aes128-cts` in CM; FreeIPA KDC via `/etc/krb5.conf.d/cldr-permitted-enctypes.conf`). RC4 is omitted because Java 17+ and Cloudera recommend AES. Do **not** set `allow_weak_crypto=true` unless you explicitly opt in with `krb5_allow_weak_rc4: true` in group_vars.

**Existing deployments** that already show `rc4-hmac` in the CM Kerberos wizard:

1. Re-run `12_setup_freeipa_server.yml` (or at least the ipaserver play in `30_setup_cm_krbs.yml`) to apply the IPA KDC snippet and restart IPA (`ipactl restart` when configured, else `krb5kdc`).
2. Re-run `30_setup_cm_krbs.yml` — it reconciles `KRB_ENC_TYPES` via the CM API even when `kerberized=true` (may restart Cloudera Manager).
3. In CM, **regenerate** cluster/service keytabs/principals so new keys use AES (CM Kerberos wizard or cluster Kerberos enablement flow). Principals created under RC4-default KDC settings may retain RC4 long-term keys until regenerated.

If `cm_admin_pass` is not the factory password (`cm_admin_bootstrap_pass`, default `admin`), `25_verify_cm.yml` and later playbooks reset the CM `admin` user to `cm_admin_pass` via the API on first successful connection.

CSD JARs for DataViz / NiFi / NiFi Registry are listed in `scm_csds_effective` during `24_start_cm.yml` (RHEL CM): built from `scm_csds_urls.j2` when `scm_csds` is empty, using `cdv_version`, `cfm_version`, and related vars. Play 24 downloads each URL directly to its exact basename under `/opt/cloudera/csd`; a failed download stops with the repository error instead of extracting a CDV parcel that may not contain the CSD JAR. By default `csd_respect_service_toggles: false` stages all configured CSDs so optional services can be enabled later; set it true to download only CSDs for enabled `base_cluster_install_services`. If a rerun adds or updates a CSD, play 24 restarts the active CM server so the descriptor is loaded. Set e.g. `cdv_version: "8.1.5"` and update `cdv_dataviz_csd_jar` to match the archive jar name, or pass an explicit `scm_csds` list of full jar URLs (replacing the auto-built list).

**CM remote parcel repositories:** Playbooks **25**, **31**, and **33** call `configure_cm_parcel_repo_api.yml`, which sets `REMOTE_PARCEL_REPO_URLS` to **pinned** CDH/ECS parcel directories plus CSD-related **parcel repository** paths only (`cdh_version`, `ecs_pvc_ds_version`, `cdv_version`, `cfm_version`). Default **`cm_parcel_repo_include_latest: false`** — use pinned version directories only. Never use `…/{latest}/parcels/` (invalid URI and not a real archive path). Optional float uses literal `…/latest/parcels/` via **`cm_parcel_repo_latest_segment: latest`** (CDH/ECS/CDV parcels only). **CDV** adds `…/cdv/<ver>/parcels/`; **CFM2** adds `…/cfm2/<ver>/redhat9/yum/tars/parcel` (not `…/parcels/` or `…/redhat8/yum` — those are CSD JAR download paths in `scm_csds_urls.j2` / **24_start_cm**). CDV/CFM dirs come from `scm_csd_parcel_repo_urls.j2` once (no duplicate merge). Scrub also drops deprecated Intel MKL, legacy wizard URLs, `.jar` paths, merged garbage URLs (`7180/cmf`, double `http://`), and any URL containing `{` or `}`. `cm_parcel_install_csd_repo_urls: false` prevents CM from re-adding CSD-derived spark/cdh6 URLs on scm-server restart.

**Example `REMOTE_PARCEL_REPO_URLS` (defaults in `group_vars/all.yml`, public archive, `cm_parcel_repo_include_latest: false`):**

```text
https://archive.cloudera.com/p/cdh7/7.3.2.0/parcels/
https://archive.cloudera.com/p/cdp-pvc-ds/1.5.5-h3300/parcels/
https://archive.cloudera.com/p/cdv/8.0.7/parcels/
https://archive.cloudera.com/p/cfm2/2.1.7.3004/redhat9/yum/tars/parcel
```

**Operator — refresh parcel repos after CM is up (playbook 25):**

```bash
cd ansible-playbooks
export ANSIBLE_PRIVATE_KEY="${ANSIBLE_PRIVATE_KEY:-$(pwd)/sshkey.pem}"
ansible-playbook -i inventory.ini 25_verify_cm.yml
```

Play **25** runs on `localhost`, delegates CM API calls to a reachable manager address, and applies scrubbed `REMOTE_PARCEL_REPO_URLS` plus `PARCEL_INSTALL_CSD_REPO_URLS=false` when `parcel_repo` is defined. Confirm in CM: **Administration → Parcel Settings → Remote Parcel Repository URLs** (Save & Verify should pass with no `{`/`}` paths). Re-run **31** / **33** later if you only need parcel repo alignment during cluster setup phases.

If CM shows **no CDV/CFM remote repos** after a run, check: (1) `cm_parcel_repo_include_cdv_parcel` / `cm_parcel_repo_include_cfm_parcel` are true and `cm_repo_source: public`; (2) `cm_parcel_repo_include_csd_archive_dirs: true` (default) so `scm_csd_parcel_repo_urls.j2` builds CDV/CFM paths — when false, set explicit `cm_remote_parcel_csd_repo_urls` or re-enable the toggle; (3) `cm_parcel_csd_respect_service_toggles: true` with `base_cluster_install_services.dataviz` / `nifi` / `nifi_registry` false yields an empty auto-built list from `scm_csd_parcel_repo_urls.j2` — leave `cm_parcel_csd_respect_service_toggles` at default **false** or enable those service keys; (4) override with explicit `cm_remote_parcel_csd_repo_urls` in `group_vars/all.yml`, Jenkins `ANSIBLE_GROUP_VARS_YAML`, or `-e`.

### 7. Run Phase 4 (CMS + base cluster)

```bash
ansible-playbook -i inventory.ini 28_setup_cm_cms.yml
ansible-playbook -i inventory.ini 31_setup_base_cluster.yml
ansible-playbook -i inventory.ini 33_setup_ecs_cluster.yml
```

`31_setup_base_cluster.yml` builds the cluster from `templates/base_cluster_cluster_spec.j2`. Toggle services with `base_cluster_install_services` in `group_vars/all.yml` or Jenkins `ANSIBLE_GROUP_VARS_YAML` (allowed key `base_cluster_install_services`). Cluster **create** runs only when the cluster does not exist in CM; adding services to an existing cluster requires CM UI/API changes.

Cluster creation is split into a create/configure phase and a First Run phase. The
`cloudera.cluster` module can spend up to two hours activating parcels or waiting
for CM commands; Ansible runs it asynchronously and Jenkins prints a poll update
every `base_cluster_module_poll_interval` seconds instead of appearing frozen.

When a base cluster with the configured name already exists, playbook **31**
reads its current state, assigned hosts, and service types. A zero-host partial
cluster left by an interrupted create is deleted and recreated. A populated
cluster is never deleted: all requested service types must already exist, then
required Ozone/Hive/Ranger/Knox settings and the Ozone Recon role are reconciled,
the cluster is started if necessary, and CM runs
`deployClientConfigsAndRefresh`. The final cluster state and health are printed.

First Run failures are expanded from the parent CM command into failed service
commands and their child validation messages in Jenkins. First Run is submitted
for a newly created cluster and for an existing populated cluster when the
initialization marker is absent **and** HDFS is not yet `STARTED/GOOD` (typical
when playbook **31** failed during Knox or other pre-First-Run configuration
before CM ever formatted the NameNode). In that case **31** skips interrupted-run
recovery and calls `POST .../commands/firstRun` instead of `commands/start`.
Once HDFS is healthy, reruns use interrupted First Run recovery or a normal
cluster start so an already formatted NameNode is never formatted again. Set
`base_cluster_force_first_run: true` only when CM support directs a deliberate
First Run retry. Database and initial service
passwords use the `base_cluster_*` variables and should be overridden through
`ANSIBLE_GROUP_VARS_YAML` or an Ansible vault. Ranger initial passwords must
contain letters and numbers and be at least eight characters long.

An interrupted First Run can leave HDFS formatted and running while later
service setup never occurred. When a populated cluster has no matching
cluster-UUID marker at `base_cluster_initialization_marker_path`, playbook **31**
performs only non-destructive recovery before normal Start: it starts ZooKeeper
and HDFS, creates HDFS `/tmp` plus the configured YARN node-label store with
the required permissions, starts Ranger and initializes its plugin services
(which populate their local policy caches), initializes Solr's HDFS home and ZooKeeper state,
creates the HBase root and user directories, creates the YARN JobHistory
directory and installs MapReduce framework JARs, creates the Spark history,
user, and driver-log directories, and creates the Hive and Impala HDFS
directories. Ozone recovery starts the SCM role alone, waits until an
authenticated `ozone admin scm roles` check reports `LEADER`, and only then
starts the remaining Ozone roles. This prevents DataNodes from exhausting
certificate-enrollment retries against a running but not-yet-leader SCM and
leaving SCM in safe mode with no healthy pipeline. CM First Run retains
responsibility for initializing SCM on a new cluster; if that initial run is
interrupted, the next Base Cluster phase applies the ordered recovery without
deleting Ozone metadata. The same ordered recovery runs for an initialized
existing cluster when the cluster remains started but Ozone is stopped or has
`BAD` health, so a later SCM or DataNode failure does not depend on the
initialization marker being absent. A deliberately stopped whole cluster uses
the normal cluster start path, and an initialized cluster does not restart
Ozone for a transient `CONCERNING` health state. Interrupted First Run recovery
continues to recover any non-`GOOD` Ozone state. The optional YARN
container-usage directory command is not part of automatic recovery; run it
only after enabling container-usage aggregation and configuring its MapReduce
job user. Recovery never invokes NameNode format or cluster First Run.

HDFS `/tmp` reconciliation first calls CM's documented
`hdfsCreateTmpDir` service command. Some CM 7.13/CDP 7.3.2 layouts return
`Command not valid for ...`; in that case Ansible probes every base master and
worker, then uses the first available HDFS client to create the namespace path
and verify mode `1777` (world-writable with sticky bit). The probe checks
`PATH`, the active `/opt/cloudera/parcels/CDH/bin/hdfs` link, and executable
versioned `/opt/cloudera/parcels/CDH-*/bin/hdfs` clients. These delegated
commands explicitly use SSH so the localhost CM orchestration play cannot run
them on the Jenkins controller. The fallback reads the authoritative
`hadoop_security_authentication` setting from CM rather than trusting
`/etc/hadoop/conf`, which can remain stale after a security transition. In
SIMPLE mode it uses `HADOOP_USER_NAME=hdfs`; after Kerberos enablement it
selects the newest CM-generated `hdfs.keytab`, uses that keytab's CM process
directory as `HADOOP_CONF_DIR`, obtains an `hdfs/*` ticket in an isolated
temporary credential cache, performs the same `/tmp` verification, and
destroys the cache on exit.
The same verification runs after a fresh First Run, so the HDFS canary can
create `/tmp/.cloudera_health_monitoring_canary_files`. This is not the local
Linux `/tmp` directory on each DataNode.
The marker is recorded only after startup and client-configuration refresh
complete successfully. CM can report a one-time setup command as
`Command not valid for ...` when that artifact is already initialized; recovery
reports that exact response as a skip and continues, but all other HTTP or
command failures remain fatal.

CM can occasionally fail First Run at `WaitForKnoxGatewayReadyToServe` even
though the Knox process subsequently reaches `STARTED/GOOD`. When that is the
only failed First Run child, playbook **31** performs a bounded Knox health
poll, then starts and polls the full cluster. It does not suppress other Knox
failures or continue while the remaining services are stopped.

`KNOX_GATEWAY=STARTED` only confirms the Java process is running. CM's
`checkTopologyDeployment.sh` separately polls
`/gateway/health/v1/gateway-status`; HTTP 200 with body `PENDING` means topology
deployment is not ready yet. The CSD's default bounded wait is 600 seconds.
Playbook **31** does not falsely convert `PENDING` to success. It applies the
recovery above only after CM ends First Run with the single
`WaitForKnoxGatewayReadyToServe` failure and Knox subsequently reports
`STARTED/GOOD`.

When `gateway.log` reports `Failed to configure truststore` followed by a
`PKIX path building failed` error while discovering the CM API, waiting cannot
recover the gateway: `cdp-proxy`, `cdp-proxy-token`, `cdp-proxy-api`, and
`cdp-datashare-access` cannot be generated. Playbook **31** configures the Knox
Gateway role's `ssl_client_truststore_*` settings from CM's Auto-TLS truststore
and password **after** `configureAutoTlsServices` and before First Run. It also
sets the Knox service `kerberos.auth.enabled` flag (when Kerberos is enabled)
and the KNOX_GATEWAY safety valve `gateway.cluster.config.monitor.cm.enabled=true`
plus `gateway.frontend.url`. When any of those change, **31** deploys Knox client
configuration and restarts an already-running Knox gateway so `gateway-site.xml`
on the host matches CM before topology discovery runs. An interrupted
initialization also forces the redacted truststore password to be refreshed,
preventing a stale Knox credential alias from producing `Keystore was tampered
with, or password was incorrect`. The expected generated `gateway-site.xml` value
is a non-empty `gateway.httpclient.truststore.path`; an empty value confirms the
trust configuration is missing.

After Knox is `STARTED`, **31** polls `https://<knox-host>:8443/gateway/health/v1/gateway-status`
until the response is no longer `PENDING` and no longer lists `cdp-proxy` or
`cdp-datashare-access` in the **Waiting for** section (same signal CM's
`checkTopologyDeployment.sh` uses). Tune `base_cluster_knox_cdp_proxy_topology_retries`
and `base_cluster_knox_cdp_proxy_topology_delay` when large clusters need more than
the default ~10 minutes.

`base_cluster_enable_kerberos: true` makes playbook **31** Kerberize every base
cluster it manages. Auto-TLS and CM KDC/account-manager integration must already
be active before cluster creation. For a newly created cluster, playbook **31**
refuses First Run unless the KDC is reachable and CM's matching credential
marker exists; it then runs `configureForKerberos`, generates credentials, and
verifies HDFS authentication **before any cluster service is started**. This
avoids initializing service state in SIMPLE mode and retrofitting security
afterward. Interrupted pre-First-Run attempts repeat credential generation and
verification before any retry starts the cluster.

For an existing initialized cluster, the playbook checks HDFS authentication.
A cluster still using `simple` authentication is stopped, configured through
CM's `configureForKerberos` command, issued fresh credentials, restarted, and
refreshed. Completion is recorded only after CM reports
`hadoop_security_authentication=kerberos`; already Kerberized clusters skip the
transition. This leaves playbook **30** responsible for CM-wide KDC integration
and account-manager credential import.

Hue's `KT_RENEWER` requires its initial keytab login to receive a renewable TGT.
Playbook **12** reconciles the FreeIPA global policy to a 24-hour maximum ticket
life and 7-day maximum renewable life. Playbook **16** deploys matching
`ticket_lifetime` and `renew_lifetime` defaults under `/etc/krb5.conf.d` on
identity clients. This applies to existing hosts when the IDENTITY phase is
rerun and to future hosts during enrollment. After changing these settings,
restart a failed Hue `KT_RENEWER` role (or start the cluster) so it performs a
new keytab `kinit`; an already-issued non-renewable TGT cannot be converted by
`kinit -R`. Verify with `klist -f`: the TGT must include the renewable flag and
a non-empty `renew until` timestamp.

Kerberized Ozone client configuration also requires the Ozone service's
`hdfs_service` dependency to reference HDFS. HDFS itself references
`CORE_SETTINGS` through `core_connector`. Playbook **31** sets the Ozone→HDFS
dependency in the new-cluster template and reconciles it on existing Ozone
services. Without that dependency CM's Ozone CSD receives no `core-site.xml`; its
`deploy_client_configs` script fails at `add_to_site ''` with
`Could not find  or  is not a file`.

### Ozone SCM, SafeMode, and certificate signing

Playbook **31** sets `ozone.scm.primordial.node.id` and attaches the single
`Master` host template to **`groups[base_cluster_master_group][0]`** only
(`cldr_hostname` + `cluster_domain`, e.g. `pvcbase-master.cldrsetup.local`).
Workers receive `OZONE_DATANODE` only; OM/SCM/Recon/S3 Gateway run on that one
master. Before First Run or recovery start, **31** runs `configureForKerberos`
(when enabled), then `generateCredentials`, then `configureAutoTlsServices`
(when Auto-TLS is on), so Ozone and other services start under Kerberos +
cluster TLS, not SIMPLE + HTTP.

**Symptoms:** `ServerNotLeaderException`, SCM SafeMode with `0/N datanodes
registered`, OM/DN cert enrollment retries, `RAFT closed`, or
`Invalid domain … in CertificateSignRequest`.

**Likely causes (check in order):**

1. **CM host FQDN vs primordial id** — In CM → Hosts, the master must be
   `pvcbase-master.<cluster_domain>` matching `ozone.scm.primordial.node.id`.
   Reconcile via playbook **31** or fix host attachment; do not mix short names
   with FQDN primordial ids.
2. **Extra SCM roles (manual HA)** — More than one `STORAGE_CONTAINER_MANAGER`
   without a supported HA template breaks Ratis leadership. This repo deploys
   **one** SCM on the first `[base-masters]` host; remove stray SCM roles or
   extend the cluster spec before expecting HA.
3. **Security phase skipped** — Run **CM_TLS_KRB_LDAP** (plays **27** → **30**)
   before **31**. Starting Ozone before `configureForKerberos` /
   `configureAutoTlsServices` causes cert/Kerberos mismatches.
4. **Interrupted First Run** — Re-run **31** without deleting the cluster: it
   stops unhealthy Ozone, starts SCM alone, waits for `ozone admin scm roles`
   `LEADER`, then starts remaining Ozone roles (see recovery section above).
5. **`.local` cluster domains** — IPA default `cldrsetup.local` is valid for
   hostnames but some Ozone/Auto-TLS cert validators log `Invalid domain` for
   internal TLDs. Confirm SANs on signed certs match the CM host FQDN; for
   production labs consider a resolvable suffix consistent with CM Auto-TLS.

**Operator checks:** SCM role logs under
`/var/log/cloudera-scm-agent/process/*-ozone-STORAGE_CONTAINER_MANAGER/`; Ratis
metadata under `/var/lib/hadoop-ozone/scm/data/` (do not delete on retry);
`ozone admin scm roles --service-id=<base_cluster_ozone_service_id>` from the
SCM host after `kinit` with the role keytab; CM → Ozone → Configuration →
`ozone.scm.primordial.node.id` and `hdfs_service`.

Playbook **31** also imports the idempotent **27** Auto-TLS workflow before base
cluster reconciliation. When `autotls_enabled: true`, CM's authoritative
`AUTO_TLS_TYPE` is checked and Auto-TLS is enabled only when absent. A newly
enabled Auto-TLS installation restarts CM and its agents through playbook **27**.
If the base cluster already existed and did not otherwise need its Kerberos
transition or interrupted-run recovery, playbook **31** then performs one
cluster stop/start and client-configuration refresh. Fresh clusters and clusters
being Kerberized are already started after the security change and avoid that
extra restart. The final initialization marker is written only after both CM
Auto-TLS and HDFS Kerberos report the requested enabled state.

After base-cluster startup, any required Auto-TLS/Kerberos restart, and client
configuration refresh complete, playbook **31** restarts Cloudera Management
Service through the CM API and waits for the restart command. The base-cluster
completion marker is not written unless CMS was running and CM accepted the
restart. Set `base_cluster_restart_cms_after_start: false` only when CMS restart
is intentionally managed outside this workflow.

Hue is configured with the external `hue` PostgreSQL database before cluster
startup. Playbook **31** reconciles the database settings for existing Hue
services as well as rendering them for new clusters, preventing reruns from
falling back to Hue's local SQLite database. It also installs and verifies
`psycopg2` inside Hue's parcel-managed Python virtual environment before First
Run; installing the driver only in `/usr/bin/python3` does not make it available
to Hue. The system targets are derived as `/usr/bin/python3` and
`/usr/bin/python{{ python_version }}`; playbook **31** discovers Hue's parcel
interpreter from the active CDH parcel (`lib/hue/build/env/bin/python` for
Python 3.11+ Hue, or `lib/hue/build/venvs/python{{ python_version }}` on older
layouts) instead of hardcoding a full venv path.

For an existing cluster, playbook **31** also detects stale Hive Metastore
catalogs whose names begin with
`cloudera_manager_metastore_canary_test_catalog_`. When found, it stops Hive,
reconciles `DBS_FK1` to `DEFERRABLE INITIALLY DEFERRED`, refuses cleanup if any
table or function belongs to a canary database, removes only CM-canary database
parameters, privileges, notification rows, database rows, and catalog rows,
then verifies that no stale canary catalog remains before cluster startup.
Deferred validation preserves the foreign key but lets Hive's `drop_catalog`
transaction batch its `CTLGS` and `DBS` deletes in either order; this prevents
each new canary run from recreating the same FK failure. Set
`base_cluster_repair_hive_canary_catalogs: false` to disable this narrowly
scoped repair. Normal Hive catalogs and databases are never selected.

For a clean base-only recreation that preserves CM, CMS, FreeIPA, ECS, and
downloaded parcels, use `rebuild-base-cluster.sh`. It previews by default:

```bash
cd ansible-playbooks
./rebuild-base-cluster.sh
```

After reviewing the cleanup targets, execute the rebuild:

```bash
./rebuild-base-cluster.sh --execute
```

The execute path first runs playbooks **27** and **30** to converge CM Auto-TLS
and KDC/account-manager integration. This happens before destructive cleanup,
so a security prerequisite failure leaves the existing cluster intact. It then
deletes the base-cluster registration and node service state, resets only the
Hive, Hue, Ranger, and Knox schemas while preserving their database
containers/login roles, and runs playbook **31**. The new cluster is configured
and verified for Kerberos before First Run, then client configuration is
refreshed and CMS is restarted. Existing initialized clusters managed by
playbook **31** receive guarded Auto-TLS/Kerberos convergence without requiring
a rebuild.

New deployments use the default cluster name `CDP-base-cluster`. When that
default is unchanged and a pre-V2 `CDH-Cluster` already exists, playbook **31**
adopts the legacy cluster instead of creating a duplicate. Explicit custom
cluster names never use this fallback.

Kafka metadata is selected with `base_cluster_kafka_metadata_store`:
`Zookeeper` (the automation default) omits KRaft roles and configures Kafka's
ZooKeeper dependency, while `KRaft` assigns both `KAFKA_BROKER` and `KRAFT`
roles to base workers. Choose the mode before Kafka's first successful start;
changing an initialized Kafka service requires a supported Kafka metadata
migration. In KRaft mode, playbook **31** adds missing controller roles to
existing clusters before startup.

**ZooKeeper placement:** When `base_cluster_install_services.zookeeper` is true (default), the **Worker** host template assigns **ZooKeeper Server** to every host in `base_cluster_worker_group` (`base-workers`). Masters use the **Master** template only. Labs typically run one or three ZK servers on workers; Cloudera Manager requires at least one Server role before Stop Cluster / Deploy Client Config (including after Kerberos/KDC is enabled manually or via playbook **28**).

**Existing cluster missing ZK Server roles:** If CM shows **ZooKeeper has 0 Servers**, the cluster was usually created before host templates used CM service **types** (`ZOOKEEPER`, not `zookeeper`) or playbook **31** found the cluster already present and only started services (templates are not reapplied). Choose one:

1. **CM UI (keep data):** Cluster → **ZooKeeper** → **Instances** → **Add Role Instances** → **Server** on each `base-workers` host (or at least one worker for a lab). Start the new roles, then retry Stop Cluster / Deploy Client Config.
2. **Recreate cluster:** `99_cleanup.yml` with `cleanup_delete_base_cluster=true`, then re-run `31_setup_base_cluster.yml` on current `main` (Worker template must list `service: ZOOKEEPER`, `type: SERVER`).

Playbook **31** validates the rendered Worker template and, after create or start, fails via the CM API if zero ZooKeeper Server roles remain.

`33_setup_ecs_cluster.yml` is skipped automatically when `[ecs-masters]` / `[ecs-workers]` are empty (`ecs_deploy_enabled: auto`).

### 8. Deployment portal (optional)

```bash
ansible-playbook -i inventory.ini 10_setup_deployment_portal.yml
# Optional monitoring (or set monitoring_stack_enabled: true in all.yml for playbook 28)
MONITORING_STACK_ENABLED=true ansible-playbook -i inventory.ini 32_setup_monitoring_stack.yml
```

Ops stack runs on **ipaserver** when present (`deployment_portal_host_group: auto`), else **cldr-mngr**.

#### Run the deployment portal independently with another inventory

The portal can be bootstrapped without running the rest of the deployment pipeline. It is not tied to Terraform-generated inventory, but the inventory must provide:

- One non-empty **portal host group**. With `deployment_portal_host_group: auto`, Ansible selects `[ipaserver]` (or legacy `[ipa_server]`) when present, otherwise `[cldr-mngr]`. For any other group name, set `deployment_portal_host_group` explicitly.
- One non-empty **PostgreSQL reference group** so pgAdmin and JDBC links can be rendered. Auto-detection checks `[postgres]`, `[postgresql]`, `[db]`, then `[cldr-mngr]`. For another name, set `postgres_inventory_group`; `deployment_portal_postgres_host_group: auto` then follows it.
- `ansible_host` and `cldr_hostname` for each displayed host. Set `private_ip` when `ansible_host` is a public address; when only a private address exists, use the same value for both.
- SSH access from the Ansible controller and passwordless `sudo`/root privilege escalation on the portal host.
- `cluster_domain`, plus connection and portal settings described below.

Minimal private-only inventory:

```ini
[portal]
portal01 ansible_host=10.20.0.10 private_ip=10.20.0.10 cldr_hostname=portal01

[database]
db01 ansible_host=10.20.0.20 private_ip=10.20.0.20 cldr_hostname=db01

# Optional groups are displayed and monitored when present.
[base-masters]
master01 ansible_host=10.20.0.30 private_ip=10.20.0.30 cldr_hostname=master01

[base-workers]
worker01 ansible_host=10.20.0.31 private_ip=10.20.0.31 cldr_hostname=worker01
```

For a cloud host, put its SSH-reachable/public address in `ansible_host` and its VPC address in `private_ip`:

```ini
[portal]
portal01 ansible_host=203.0.113.10 private_ip=10.20.0.10 cldr_hostname=portal01
```

Keep secrets out of the inventory and command line. Create a local, uncommitted `portal-vars.yml`:

```yaml
cluster_domain: example.internal
deployment_environment: baremetal
deployment_portal_access_profile: private

deployment_portal_host_group: portal
postgres_inventory_group: database
deployment_portal_postgres_host_group: auto

deployment_portal_enabled: true
caddy_vhost_enabled: true
deployment_portal_ipa_https_enabled: true

# Set false for a portal-only run that must not install monitoring exporters
# on the other inventory hosts.
monitoring_stack_enabled: false

ansible_user: automation
ansible_ssh_private_key_file: /secure/path/cluster.pem

postgres_password: REPLACE_ME
pgadmin_default_email: admin@example.com
pgadmin_default_password: REPLACE_ME
deployment_portal_basic_auth_user: portal
deployment_portal_basic_auth_password: REPLACE_ME
```

For public/cloud URL output, use `deployment_environment: aws` (or `deployment_portal_access_profile: cloud`) and retain distinct public `ansible_host` and `private_ip` values. Optional `[ipaserver]`, `[cldr-mngr]`, `[base-masters]`, `[base-workers]`, `[ecs-masters]`, and `[ecs-workers]` groups add their corresponding URLs and role information. If `[ipaserver]` is present, it must be the real FreeIPA server because Caddy will proxy `/ipa/*` to its HTTPS listener using `cldr_hostname.cluster_domain` as TLS SNI and the HTTP `Host`.

From the repository:

```bash
cd ansible-playbooks

# Validate group names, host variables, SSH, and privilege escalation first.
ansible-inventory -i /path/to/inventory.ini -e @/secure/path/portal-vars.yml --graph
ansible all -i /path/to/inventory.ini -e @/secure/path/portal-vars.yml \
  -m ansible.builtin.ping --become

# First run: install Docker/Compose and bootstrap Caddy + pgAdmin.
./run-playbook.sh -i /path/to/inventory.ini \
  -e @/secure/path/portal-vars.yml \
  10_setup_deployment_portal.yml

# Later runs: re-render URLs, credentials, Caddy, and detected monitoring data.
# This intentionally fails if the bootstrap compose file is not already present.
./run-playbook.sh -i /path/to/inventory.ini \
  -e @/secure/path/portal-vars.yml \
  35_refresh_deployment_portal.yml
```

`run-playbook.sh` installs the collections from `requirements.yml` when needed. Direct `ansible-playbook` execution also works because the playbooks import `ensure_collections.yml`. The portal host needs outbound access to the Docker repository, Docker Hub, and (if the packaged Compose plugin is unavailable) GitHub or PyPI. When Caddy is colocated with FreeIPA, HTTP/HTTPS default to **81/9443** because IPA Apache owns 80/443 and Dogtag PKI commonly owns 8443-8445. When `deployment_portal_host_group` selects a non-IPA dedicated proxy, the defaults are standard **80/443**. Explicit `deployment_portal_http_port` and `deployment_portal_ipa_https_port` values override this selection; the playbook checks that the effective HTTPS port is available before starting Compose. Allow both effective ports from portal users; allow `deployment_portal_pgadmin_host_port` (default **5050**) only when direct pgAdmin access is wanted. If monitoring is enabled, also account for the monitoring ports documented below.

After bootstrap, verify `http://<portal-host>:81/`, then inspect the generated files and containers on the portal host:

```bash
sudo docker compose -f /opt/cldr-deployment-portal/docker-compose.yml ps
sudo docker logs cldr-portal-caddy --tail 100
sudo sed -n '1,220p' /opt/cldr-deployment-portal/Caddyfile
```

**AWS (public IP):** Jenkins and browsers on the internet use `http://<ops-public-ip>:81/`; hosts inside the VPC can use `http://<ops-private-ip>:81/`. The generated index lists both. Caddy vhost URLs use a **dashed** ops public IP in the hostname (`portal.52-221-251-41.pvc.cloudera-labs.com`, not dotted); that requires wildcard DNS on `caddy_vhost_public_base` or use `caddy_vhost_dns_mode: classic_nipio`. Playbook 28 fails fast if Caddy does not respond on `http://127.0.0.1:<deployment_portal_http_port> (default 81)/` on the ops host.

**Caddy FreeIPA vhost:** When `[ipaserver]` is present, the preferred URL is `https://ipa.<ops-ip-dashed>.<base>:9443/`; its HTTP `:81` vhost redirects to HTTPS and `/` redirects to `/ipa/modern-ui/` (legacy UI remains under `/ipa/ui/`). Caddy uses its persistent internal CA because ports 80/443 are already owned by FreeIPA Apache and 8443-8445 are reserved for Dogtag PKI on the default ops host. Download `/downloads/caddy-root-ca.crt` after portal login and trust it in the operator browser/OS once. Caddy connects over **HTTPS** to the IPA inventory address (`private_ip`, then `ansible_host`) so its container does not need to resolve the IPA DNS zone, while using the IPA FQDN for TLS SNI and **`Host`**. The shared IPA proxy route remains mounted on the direct-IP HTTP listener at `http://<ops-public-or-private-ip>:81/ipa/...` as a fallback. That fallback removes the upstream cookie's `Secure` attribute; the preferred HTTPS vhost retains it. Path matchers set IPA’s required HTTPS `Referer`, disable JSON compression through the proxy, and rewrite upstream redirects/cookie domains. **`GET /ipa/session/login_kerberos` → 401** is expected when **`ipa_httpd_disable_browser_krb_negotiate: true`** — use password login. **Default:** no ipaserver httpd edits — Caddy alone fronts the UI. Optional **`deployment_portal_ipa_httpd_proxy_enabled: true`** adds Apache **`mod_substitute`** on UI paths only (not `/ipa/json`).

**IPA Apache behind Caddy (ipaserver, opt-in):** Default **`deployment_portal_ipa_httpd_proxy_enabled: false`** — no ipaserver httpd edits; ops Caddy reverse-proxies HTTPS to the ipaserver inventory address on port 443. Jenkins **PORTAL** and playbook **16** run **`remove_ipa_httpd_caddy_proxy_on_ipaserver.yml`** (absent **`zz-ipa-caddy-proxy.conf`**, revert **`ipa-rewrite`** Caddy markers, **`systemctl reload httpd`** when changed). When the flag is **true**, the same entry points run **`configure_ipa_httpd_behind_caddy.yml`** (`mod_substitute` on UI paths only, **`ipa-rewrite`** patches, **`apachectl configtest`**, httpd reload — not **`ipactl restart`**). Manual check: `apachectl configtest && systemctl reload httpd`.

### Jenkins **PORTAL** and **IDENTITY** rerun — config and automatic restarts

| Jenkins stage | Playbooks (phase) | Kerberos / IPA / httpd config | Automatic service actions |
|---|---|---|---|
| **PORTAL** | `10_setup_deployment_portal.yml` (+ optional `35_refresh` at end of later phases) | Re-renders Caddy, portal index, pgAdmin compose; **`manage_ipa_httpd_caddy_proxy_on_ipaserver.yml`** (Caddy proxy snippets per flag + **`zz-ipa-disable-browser-krb.conf`** when **`ipa_httpd_disable_browser_krb_negotiate`**) | **Caddy** **force-recreate** when templates change; **httpd reload** when ipaserver httpd snippets change |
| **IDENTITY** | Phase 2: `11_identity_setup.yml` → **`12_setup_freeipa_server.yml`** (ipaserver) + **`16_setup_identity_client.yml`** (`all:!ipaserver` clients); ends with **`35_refresh`** when portal refresh is enabled | **`12`:** `/etc/krb5.conf.d/ansible-ccache-note.conf`, **ipaserver** KEYRING **`default_ccache_name`** restored (clients commented), enctypes snippet; **`ipactl restart`** when enctypes snippet or main krb5.conf changes. **`16`:** ccache drop-in on **ipaserver** before enroll; **`join_freeipa_client`** comments KEYRING **`default_ccache_name`** after enroll on clients; **`sync_ipa_httpd_caddy_proxy_state_on_ipaserver.yml`** (default: cleanup only; opt-in apply + **`/ipa/json`** HTML preflight when **`deployment_portal_ipa_httpd_proxy_enabled: true`**) | **`16`:** **SSSD restart** on a client when krb5.conf or the ccache drop-in changes and **SSSD** is already active. **`ipa-client-install`** uses **Kerberos**, not an unauthenticated **`/ipa/json`** probe. Ansible **`ipa`/`kinit`** still use **`KRB5CCNAME=FILE:{{ ipa_kerberos_ccache_path }}`** only. Portal index refresh only — not a substitute for **PORTAL** Caddy compose |

**Operator takeaway:** Re-run **IDENTITY** to push fleet **`ansible-ccache-note.conf`**, refresh FreeIPA server krb5 snippets (with **`ipactl restart`** when enctypes change), and re-enroll or verify clients. Re-run **PORTAL** for Caddy/portal stack updates; by default Ansible **removes** legacy ipaserver **`zz-ipa-caddy-proxy.conf`** and reloads **httpd** when needed. Set **`deployment_portal_ipa_httpd_proxy_enabled: true`** only when you need Apache HTML rewrites on ipaserver.

**IPA Web UI — password/form login only (no browser Kerberos/SPNEGO):** By default **`ipa_httpd_disable_browser_krb_negotiate: true`** installs **`/etc/httpd/conf.d/zz-ipa-disable-browser-krb.conf`** on **ipaserver** (`SetEnv gssapi-no-negotiate` on **`/ipa`** per **mod_auth_gssapi**). Apache stops sending **`WWW-Authenticate: Negotiate`**; the modern UI uses **forms-based login** (`admin` / **`ipaadmin_password`**). This drop-in survives **`ipactl restart`** (not regenerated by **`ipa-server-install`**). **`ipa` CLI**, **`ipa-client-install`**, and Ansible still use **Kerberos** with **`KRB5CCNAME=FILE:{{ ipa_kerberos_ccache_path }}`** — not browser negotiate.

**Where to open the UI:** **`https://ipa.<ops-ip-dashed>.<base>:9443/`** (Caddy on ops; trust the downloadable Caddy root CA first) or **`https://ipaserver.<domain>/ipa/modern-ui/`** (direct; resolve via lab DNS or `/etc/hosts`). `http://ipa.<ops-ip-dashed>.<base>:81/` redirects to the HTTPS Caddy URL. Set **`ipa_httpd_disable_browser_krb_negotiate: false`** only if you need browser Kerberos SSO on the direct **ipaserver** FQDN (stock `ipa.conf` GSSAPI).

**IPA modern UI — HTTP 401 / “obtain Kerberos tickets” (legacy):** If **`zz-ipa-disable-browser-krb.conf`** is missing, the UI may try **SPNEGO** first. On the Caddy hostname there is no matching **`HTTP/ipa.<slug>…`** service principal — re-run **`12_setup_freeipa_server.yml`** or Jenkins **PORTAL**/**IDENTITY** to apply the snippet. **`deployment_portal_ipa_httpd_proxy_enabled: true`** only rewrites embedded FQDNs in HTML. On **ipaserver**, **`ensure_krb5_default_ccache_commented.yml`** keeps **`default_ccache_name = KEYRING:persistent:%{uid}`** active by default for server-side **`kinit`**; enrolled **clients** comment KEYRING for Ansible **`KRB5CCNAME=FILE:…`**.

**Kerberos `kinit` / `klist` by host role (Ansible FILE ccache only):** On **clients**, **`ensure_krb5_default_ccache_commented.yml`** keeps FreeIPA’s KEYRING **`default_ccache_name`** commented — that is **config**, not ticket acquisition. **ipaserver:** **`12_setup_freeipa_server.yml`**, **`14_setup_dns_records.yml`**, and **`19_setup_wildcard.yml`** import **`ensure_ipa_kerberos_ticket_with_klist.yml`** (host keytab first when **`/etc/ipa/default.conf`** exists, admin password fallback, **`klist -e`** logged). **cldr-mngr and workers** (`identity_client_hosts` = **`all:!ipaserver`**): **`16_setup_identity_client.yml`** → **`join_freeipa_client.yml`** uses the same FILE ccache pattern for **`ipa ping`**; admin password **`kinit` runs only when no ticket and host keytab **`kinit` failed** — not a fleet-wide admin password step on every worker.

**Running Ansible from ipaserver:** Playbook **06** copies an operator inventory, SSH key, and Ansible configuration to `/root`. Unlike the Jenkins/controller inventory, `/root/inventory.ini` rewrites each `ansible_host` to its `private_ip`, because connections originating inside the VPC should not hairpin through public addresses. `/root/ansible.cfg` selects that inventory and `/root/sshkey.pem`, and suppresses warnings for the established hyphenated group names. After rerunning **PREREQS**, root can run commands directly, for example `ansible cm-node -b -m ping`.

**Auto-TLS reports `/etc/ipa/ca.crt` missing:** FreeIPA trust is optional for `generateCmca`; CM Auto-TLS can use its own generated CA. When `use_freeipa_for_crt_mgmt=true`, automation first checks cldr-mngr and then tries to copy the authoritative CA from the inventory `ipaserver`. If neither has a non-empty CA file, playbook **27** warns and continues without `trustedCaCerts` instead of blocking Auto-TLS. The **IDENTITY** phase remains strict: every FreeIPA client must have the remote FQDN, non-empty `/etc/ipa/default.conf` and CA bundle, `/etc/krb5.keytab`, the matching `host/<fqdn>@REALM` principal, host-keytab `kinit`, and authenticated `ipa ping`. Rerun **IDENTITY** before LDAP/Kerberos integration to repair the current IPA deployment.

**`ipa-client-install` / `zlib.error` on `/ipa/json` schema RPC** (log shows session cookie OK, then `invalid code lengths set`): **`ipa-client-install`** talks to **`https://ipaserver.<domain>/ipa/json`** on the IPA server (not the Caddy `:81` UI vhost). A broken **`zz-ipa-caddy-proxy.conf`** that runs **`mod_substitute`** on **`application/json`** under **`/ipa`** corrupts **gzip** JSON-RPC bodies. From a failing worker (replace FQDNs):

```bash
IPA=ipaserver.cldrsetup.local
# Use the IPA server FQDN (not https://localhost) — ipa-client-install does. localhost with TLS often 301s to http://<FQDN>/ipa/... (HTML if followed).
# Direct HTTPS to IPA — expect HTTP 401 (or 200) with Content-Encoding: gzip; body must gunzip (not HTML starting with <!)
curl -vk -H 'Accept-Encoding: gzip' -H 'Content-Type: application/json' \
  -d '{"method":"ping","params":[[],{}],"id":0}' "https://${IPA}/ipa/json" -o /tmp/ipa.json.gz
python3 -c "import gzip; gzip.decompress(open('/tmp/ipa.json.gz','rb').read()); print('gzip OK')"
# Through Caddy IPA vhost (optional): compare with Host header to ipa.<ops-ip-dashed>.<base>
curl -v -H 'Host: ipa.<ops-ip-dashed>.pvc.cloudera-labs.com' -H 'Accept-Encoding: gzip' \
  -H 'Content-Type: application/json' -d '{"method":"ping","params":[[],{}],"id":0}' \
  "http://<ops-ip>:81/ipa/json" -o /tmp/ipa-via-caddy.gz
```

On **ipaserver**, remove or fix a stale **`zz-ipa-caddy-proxy.conf`** (SUBSTITUTE only on **`/ipa/ui`** and **`/ipa/modern-ui`**, not **`/ipa/json`**); **`apachectl configtest && systemctl reload httpd`**. To apply the managed snippet, set **`deployment_portal_ipa_httpd_proxy_enabled: true`** and re-run Jenkins **PORTAL** or playbook **16** (Ansible then POST-probes **`/ipa/json`** for HTML after httpd rewrites). **Default play 16** does **not** probe **`/ipa/json`**: unauthenticated requests often return **401 `text/html`** on stock IPA even after **`zz-ipa-caddy-proxy.conf`** cleanup — that is **not** proof of gzip corruption; **`ipa-client-install`** authenticates with Kerberos. Use the **`curl`** / **`gzip OK`** check above when diagnosing **`zlib.error`**. Re-run **`16_setup_identity_client.yml --limit <host>`** after ipaserver is healthy.

**Recovery after a failed client enroll (e.g. pvcecs-worker4, gzip fixed on ipaserver):**

1. On the worker: `test -f /etc/ipa/default.conf && echo enrolled || echo not enrolled`; `ls -la /var/lib/ipa-client/sysrestore/ 2>/dev/null`; `tail -50 /var/log/ipaclient-install.log`.
2. Verify JSON-RPC gzip from the worker (replace domain): run the **`curl`** / **`python3 -c "import gzip; ..."`** block above against **`https://ipaserver.<domain>/ipa/json`** — must print **`gzip OK`** after the httpd fix.
3. **Uninstall before retry?** **No** when **`default.conf` is absent** and **`/var/lib/ipa-client/sysrestore/`** has only an empty directory (RPM layout) — re-run playbook **16** only. **Yes** (or let playbook **16** do it) when **`default.conf` is absent** but **`sysrestore.index`** or **`sysrestore.state`** remains from a failed run (the installer may report *IPA client is already configured*). A lone **`/etc/ipa/ca.crt`** is diagnosed as incomplete state but does not invoke uninstall because no client sysrestore transaction exists. Manual: `ipa-client-install --uninstall --unattended` as **root** on the worker. Playbook **16** (`join_freeipa_client.yml`) runs that uninstall automatically when sysrestore markers are detected.
4. **Optional preflight:** **`ipa_client_preflight_enabled`** defaults to **`false`** in `group_vars/all.yml`. When **`true`**, playbook **16** runs hostname/DNS **`getent`** asserts on hosts without **`default.conf`** before **`ipa-client-install`**. There is no HTTPS **`/ipa/json`** probe (removed — it failed every enrolling host when ipaserver httpd was misconfigured; use the **`curl`** gzip check above instead). Failed installs still surface **`/var/log/ipaclient-install.log`** via **`join_freeipa_client.yml`**.
5. Re-run: `cd ansible-playbooks && ansible-playbook -i inventory.ini 16_setup_identity_client.yml --limit pvcecs-worker4` (set **`ANSIBLE_PRIVATE_KEY`** or key in playbook dir). After a gzip fix, you do **not** need to uninstall on workers that already have **`/etc/ipa/default.conf`** (they skip install).

**Cloudera Manager (not via Caddy):** Use direct **`https://<cldr-mngr-fqdn>:7183`** (or `:7180` before Auto-TLS) from browsers and Jenkins Tier **B**. Caddy on the ops host serves portal, pgAdmin, monitoring, and IPA only. Optional `cm_external_url` sets a custom published CM URL in portal facts; it does not configure Caddy.

**ECS console (not via Caddy):** Published console URL is **`https://console.<ecs_app_domain>`** (`ecs_control_plane_url_effective`). Override with `ecs_control_plane_url` when needed. Internal ECS **`ApplicationDomain`** stays `ecs_app_domain`.

**Bare metal / private network (no public IP):** Set `deployment_environment: baremetal` (or `deployment_portal_access_profile: private`). The portal index shows only private-network URLs — typically `http://<ops-fqdn>:81/` when `deployment_portal_prefer_fqdn_urls: true`, or `http://<management-ip>:81/` otherwise. pgAdmin stays on port `5050` on the same ops host; database is **cldr-mngr** PostgreSQL. Caddy lab hostnames use the ops management IP (often `caddy_vhost_dns_mode: flat` with IPA/AD DNS).

**Node URL display:** Whenever a portal web or JDBC endpoint uses an inventory node FQDN under `cluster_domain`, the portal shows the FQDN first, followed by distinct clickable public-IP and private-IP web alternatives or copyable JDBC alternatives in parentheses. Paths, schemes, and ports are preserved; Caddy lab hostnames remain unpaired because their DNS name already encodes or resolves to the intended edge address.

**Portal section ownership:** Quick-open cards provide navigation without repeating URL text, followed by a compact CM/CDP Runtime/CDS version strip. Network access shows addressing/profile facts, the Caddy section shows DNS/routing configuration, and platform sections own their detailed URLs. Operator credential tables include one bundled access column: Caddy or FQDN first, then available public-IP and private-IP alternatives; PostgreSQL uses the equivalent JDBC format.

**Portal PEM downloads:** The host-login PEM is the preferred download. When the resolved Auto-TLS key has identical file content, it is omitted even if it was discovered under a different path or filename; a second Auto-TLS download is shown only for a genuinely distinct key.

**Portal controls:** Successful HTTP Basic authentication to `/downloads/*` sets a portal marker so the header changes from **Login** to **Logout**. Operator credentials are loaded from the protected `/downloads/operator-access.html` fragment only after login; before login the panel shows a sign-in message and PEM download controls are replaced by a login action. Logout clears the marker, protected content, browser site data where supported, and sends an invalid Basic credential before returning home. Because HTTP Basic credentials are browser-managed, a browser may retain them until the tab or browser closes even though the portal immediately returns to its logged-out UI. The portal also provides quick-service filtering (`/` focuses it and `Esc` clears it), copy buttons for rendered commands, expand/collapse-all controls, a scroll-progress indicator, and fixed jump-to-top/jump-to-bottom buttons.

**Operator access hub:** After `10_setup_deployment_portal.yml` or `35_refresh_deployment_portal.yml`, the index includes an **Operator access — credentials & downloads** panel when `deployment_portal_expose_credentials: true` (default). See [Deployment portal default credentials](#deployment-portal-default-credentials) below for downloads auth, `operator-credentials.json`, lab defaults, and overrides.

#### Deployment portal default credentials

Operators use the deployment portal index on the ops host (`http://<ops>:81/` by default). The **index HTML stays unauthenticated** (Ansible Tier A verify), but it does not embed operator secrets when HTTP Basic auth is enabled. After login, the browser loads the protected Operator access fragment from **`/downloads/operator-access.html`**. PEMs and the JSON bundle remain under **`/downloads/`**.

| Surface | Path / UI | Authentication |
|---------|-----------|----------------|
| Portal index | `:81/` | None |
| Operator access panel | Collapsible section on the index; content loaded from `/downloads/operator-access.html` | Portal session login when enabled; otherwise lab/trusted networks only |
| SSH PEMs, JSON bundle | `/downloads/ssh/*`, `/downloads/operator-credentials.json` | Revocable portal session when `deployment_portal_basic_auth_enabled: true` (default) |

**Downloads session authentication** applies to **`/downloads/*` only** (not the index). Username: `deployment_portal_basic_auth_user` (default `portal`). Password: `deployment_portal_basic_auth_password` (default resolves to **`postgres_password`** — lab value `postgres`). Caddy verifies the password only at `/api/login`; the private `cldr-portal-auth` sidecar issues an opaque `HttpOnly` cookie and keeps the active-session registry in memory.

**Portal header Login** opens **`/login.html`** rather than the browser Basic Auth prompt. Successful login returns to the portal (or to the originally requested protected download). **Logout** calls the session service, removes the token from its server-side registry, expires the cookie, and returns to the unauthenticated panel. Reusing the old cookie after logout returns `401` or redirects to login. Sessions also expire after `deployment_portal_session_ttl_seconds` (default 8 hours), and all sessions are invalidated when the auth container restarts.

**Operator access panel** mirrors Ansible at sync time: Cloudera Manager (`cm_admin_user` / `cm_admin_pass`), PostgreSQL and pgAdmin, FreeIPA or AD join when configured, Grafana/Prometheus paths when monitoring is enabled, optional Ranger/Knox/Hue/ECS/Jenkins rows from the same vars as playbooks. Nothing is stored in git; re-run `35_refresh_deployment_portal.yml` after changes.

**`operator-credentials.json`** — machine-readable copy of the panel (`basic_auth_enabled`, `auth_username`, `downloads_path_prefix`, `sections[]` → `credentials[]` with `label`, `username`, `password`, `url`, `note`). Rendered to `/downloads/operator-credentials.json` from `deployment_portal_operator_credentials.json.j2`. It requires the same portal session as PEM downloads when enabled. Example:

```bash
curl -fsS -u "${DEPLOYMENT_PORTAL_BASIC_AUTH_USER:-portal}:${DEPLOYMENT_PORTAL_BASIC_AUTH_PASSWORD}" \
  "http://<ops-host>:81/downloads/operator-credentials.json" | jq .
```

**Lab default passwords (portal view):** In a fresh lab, CM is typically `admin` / `admin`, IPA admin `admin` / `PseTeam@123`, and pgAdmin, Grafana, and portal downloads auth often share **`postgres_password`** (`postgres`). EC2 SSH uses inventory user `ec2-user` with PEMs under `/downloads/ssh/` when `deployment_portal_expose_ssh_keys: true` (default). Full Ansible variable names and literals: [REFERENCE.md — Lab default passwords](REFERENCE.md#lab-default-passwords-override-before-production) — override there or below; do not paste production secrets into tickets.

**Overrides:** Set passwords and portal toggles in `group_vars/all.yml` or Jenkins job parameter **`ANSIBLE_GROUP_VARS_YAML`**, which accepts any valid Ansible variable mapping. Then run **`35_refresh_deployment_portal.yml`**.

**SSH key downloads:** `deployment_portal_expose_ssh_keys` — **`true`** (default) requests controller-key export; **`false`** disables it. The effective export is always forced off when `deployment_portal_basic_auth_enabled` is false, so PEMs are never placed in public downloads. With authentication enabled, two labeled PEMs appear when Terraform `sshkey.pem` and a distinct Auto-TLS key both exist. Host Inventory hides both header and per-row PEM links until `/api/session` succeeds; raw logged-out `/downloads/*` requests return `401`. Protected responses use `no-store`, download links include the portal generation revision, and logout revokes the token and asks the browser to clear site cache.

---

## Scenario B — Bare metal with Active Directory

### 1. Inventory (no ipaserver)

```ini
[cldr-mngr]
cldr-mngr ansible_host=10.54.75.123 private_ip=10.54.75.123 cldr_hostname=cldr-mngr

[base-masters]
pvcbase-master ansible_host=10.54.75.74 private_ip=10.54.75.74 cldr_hostname=pvcbase-master
```

Leave `[ipaserver]` empty or commented out.

### 2. Configure AD in group_vars/all.yml

```yaml
identity_provider: auto
deployment_environment: baremetal
ad_domain: corp.example.com
ad_kdc_host: 10.54.75.10
ad_dns_servers:
  - "{{ ad_kdc_host }}"
ad_join_user: svc-cloudera-join
ad_join_password: "ChangeMe@123"
```

### 3. Detect and verify

```bash
ansible-playbook -i inventory.ini detect_identity.yml
```

Expected: `effective identity provider: ad`

### 4. Prerequisites + identity

```bash
# Phase 1
ansible-playbook -i inventory.ini 00_setup_ssh_preqs.yml --limit 'all:!ipaserver'
# ... run 01-09 or use pvc_setup.sh

# Phase 2 (DNS + realm join only — skips FreeIPA server playbooks)
ansible-playbook -i inventory.ini 11_identity_setup.yml
```

### 5. Cloudera Manager + AD integration

```bash
ansible-playbook -i inventory.ini 24_start_cm.yml
ansible-playbook -i inventory.ini 26_setup_cm_license.yml
ansible-playbook -i inventory.ini 27_setup_cm_autotls.yml
ansible-playbook -i inventory.ini 28_setup_cm_cms.yml
ansible-playbook -i inventory.ini 29_setup_cm_ldap.yml
ansible-playbook -i inventory.ini 30_setup_cm_krbs.yml
```

Continue with CMS and base cluster as in Scenario A step 7.

---

## Scenario C — macOS control node (wrapper scripts)

```bash
# From a directory containing .tfvars.env or .tfvars.yaml and license.txt
./clone_and_run_pvc_automation.sh
```

Requirements on macOS:
- **bash** (scripts use `#!/usr/bin/env bash`)
- **Homebrew** for auto-install of Terraform, AWS CLI, `jq`
- `.tfvars.env` or `.tfvars.yaml` in the current directory (or set `TFVARS_FILE`)

YAML example (`.tfvars.yaml`):

```yaml
aws_region: ap-southeast-1
environment: development
cm_version: "7.13.2.6"
instance_groups:
  cldr_mngr:
    count: 1
    instance_type: m5.4xlarge
    volume_size: 300
```

See repo root `.tfvars.yaml` for the full template.

---

## E2E validation checklist (greenfield Jenkins)

Use this after **DESTROY_STACK** (or a new `ENVIRONMENT` workspace) for a full regression of Kerberos, CMS, and agent heartbeat.

### EC2 start / stop / describe (ipaserver)

| Step | Jenkins / CLI |
|---|---|
| 0 | **Terraform (TERRAFORM stage):** `ipaserver_ec2_startstop_iam_enabled=true` (default) attaches an IAM instance profile to **ipa_server** EC2 with `ec2:DescribeInstances`, `ec2:DescribeInstanceStatus` (unscoped), and `ec2:StartInstances` / `ec2:StopInstances` scoped to **`tag:environment`** = `pvc_cluster_tags.environment` (Jenkins **`ENVIRONMENT`** / `deployment_name_prefix`, e.g. `ptgtyv1` — not the Jenkins UI default `development` unless that is your workspace) and **`tag:Group`** ∈ Terraform `instance_groups` keys. **Re-run terraform apply** after changing IAM, `instance_groups`, or `environment` so the profile attaches to ipaserver. |
| 1 | Playbook **`36_install_ipaserver_ec2_startstop.yml`** runs on **`PORTAL`** (after playbook 10) and again at the start of **`IDENTITY`** (before FreeIPA/AD playbooks) so the script exists even if IPA install fails later. **`STARTSTOP_AUTOMATION`** re-runs deploy via playbook **37** when **`EC2_STARTSTOP_DEPLOY_SCRIPT=true`**. On ipaserver: **`ls -la /root/*_cldr_ec2_strt_stp.sh`** (prefix = sanitized Jenkins **`ENVIRONMENT`** / **`deployment_name_prefix`**, e.g. `ptgtyv1_cldr_ec2_strt_stp.sh`). |
| 2 | Jenkins: check **`STARTSTOP_AUTOMATION`** (in **`PIPELINE_STAGES`** — use **`REFRESH_JENKINSFILE=YES`** if the checkbox is stale). Set **`EC2_STARTSTOP_DEPLOY_SCRIPT`** / **`EC2_STARTSTOP_RUN_SCRIPT`**, **`EC2_STARTSTOP_OPERATION`** (`describe` \| `start` \| `stop`), **`EC2_STARTSTOP_GROUPS`** (comma-separated Terraform `instance_groups` keys → EC2 tag **`Group`**; **never `ipa_server` for start/stop**), and **`ENVIRONMENT`** (→ tag **`environment`**; must match your workspace, e.g. `ptgtyv1`). |
| 3 | **`stop` from Jenkins:** set **`EC2_STARTSTOP_CONFIRM=true`**. Manual stop on ipaserver: `<script> stop <prefix> <hostgroup> …` prompts **`yes`** (`<prefix>` = EC2 **`tag:environment`** / Jenkins **`ENVIRONMENT`**; script basename from **`deployment_name_prefix`**). Manual runs use **ipaserver IMDS** credentials, not the Jenkins agent AWS profile. |
| 4 | Example on ipaserver: `ptgtyv1_cldr_ec2_strt_stp.sh describe ptgtyv1 pvcbase_worker pvcecs_worker` (prefix = Jenkins **`ENVIRONMENT`** / EC2 **`tag:environment`**; also `/root/<basename>`) |

### Tear down (fresh stack)

| Step | Jenkins / CLI |
|---|---|
| 1 | `PIPELINE_STAGES` includes **`DESTROY_STACK`** (alone or last in the same build after other stages). |
| 2 | Set **`DESTROY_STACK_CONFIRM=true`** (required unless `DRY_RUN=true` for destroy plan only). |
| 3 | Optional: **`CLEANUP_BEFORE_DESTROY=true`** runs `99_cleanup.yml` with `cleanup_e2e=true` before `terraform destroy`. |
| 4 | Match **`OWNER`** and **`ENVIRONMENT`** to the workspace you intend to wipe (same tfvars as deploy). |
| 5 | CLI equivalent: `DESTROY_STACK_CONFIRM=true ./clone_and_run_terraform_destroy.sh` (see repo root / `jenkins/scripts/run-destroy-stack.sh`). |

### Full deploy stage order (fixed)

`VALIDATE` → `TERRAFORM` → `PREREQS` → `PORTAL` (when `DEPLOYMENT_PORTAL_ENABLED`) → `IDENTITY` → `CM_INSTALL` → **`CM_TLS_KRB_LDAP`** → `CDH_INSTALL` → `MONITORING` (optional) → `ECS_INSTALL` (optional).

**`CM_TLS_KRB_LDAP`** runs `pvc_setup.sh` phase **`cm_tls`** in Labs order: **`27` → `29` → `30` → `28`** (Auto-TLS, CMS, LDAP, Kerberos).

Set **`ANSIBLE_GROUP_VARS_YAML`** (or `group_vars/all.yml`) so **`ipaadmin_password`** / **`common_password`** match the FreeIPA install; Jenkins maps **`OWNER`** → `deployment_owner` and **`ENVIRONMENT`** → `deployment_name_prefix`.

### Post-deploy verification

| Area | What to check |
|---|---|
| **Kerberos / KDC** | Playbook **28** ends with `verify_cm_kerberos_enabled.yml` (`GET /cm/kerberosInfo` → **`kerberized=true`**, realm matches `cluster_realm`). CM API Kerberos REST uses **HTTPS :7183** when Auto-TLS is on. On ipaserver: `ipactl status` → **`krb5kdc` RUNNING**. |
| **CMS monitors** | CM → **Cloudera Management Service**: **Service Monitor**, **Host Monitor**, **Event Server** **RUNNING**; firehose port listening (playbook **29**). Host load/disk/memory columns populate when Host Monitor is healthy. |
| **Agent heartbeat** | CM → **Hosts**: **Last Heartbeat** fresh (~minutes) on all commissioned hosts. If stale: re-run **27** (agent reconcile) or **`reconcile_cm_agents.yml`**; confirm SG **7182/7183** agent→manager and `use_tls` after **27**. |
| **ZooKeeper** | Base cluster → **ZooKeeper** → at least one **Server** role on `base-workers` (playbook **31** fails if zero servers). Required before Stop Cluster / Deploy Client Config after KDC. |
| **Portal / URLs** | `jenkins/artifacts/access-urls.txt` and deployment portal index (when enabled). |

Re-run **`CM_TLS_KRB_LDAP`** only after **`CM_INSTALL`** (and **`IDENTITY`** for FreeIPA) if a mid-pipeline fix is needed; for KDC-only issues re-run **`30_setup_cm_krbs.yml`** from `ansible-playbooks/`.

### When to restart `cloudera-scm-server` / `cloudera-scm-agent` (automation gates)

Cloudera requires a **CM Server restart** after mutating `/cm/config` (Kerberos, LDAP, Auto-TLS `generateCmca`, JDBC-related server files). **Agents** must restart after **Auto-TLS** (new agent certs / `use_tls`) or when **`config.ini`** (`server_host`, `use_tls`) changes; they do **not** need restart for idempotent package install, **`ensure_cm_postgres_databases`** (play **29** DB ensure only), or CMS API start when roles are already healthy.

| Trigger | `cloudera-scm-server` | `cloudera-scm-agent` | Playbook / task |
|--------|------------------------|----------------------|-----------------|
| Auto-TLS `generateCmca` applied | **Required** | **Required** (cluster-wide; reconcile + one-shot gate in **27**) | `apply_cm_restart_after_config.yml`, `reconcile_cm_agents.yml`, `mandatory_restart_cm_agent_after_autotls.yml` (mandatory wave only when `cm_agent_reconcile_after_autotls: false`) |
| Auto-TLS already complete (API + truststore present) | Skip | Skip | **27** `cm_autotls_noop_this_run` |
| Kerberos `/cm/config` PUT or `importAdminCredentials` | **Required** | Optional (manager agent skipped when `cm_scm_server_restart_manager_agent: auto`) | **28** `apply_cm_restart_after_config.yml` when `cm_restart_after_config_change` |
| LDAP settings changed | **Required** (+ manager agent in `restart_cm_services.yml`) | Same play as server | **30** when `cm_restart_after_config_change` |
| PostgreSQL server restart while CM was up | **Required** (refresh JDBC pools) | No | `restart_postgresql.yml` |
| CM package install / `db.properties` already present | Start if inactive only | `restart_cm_agent_if_needed.yml` (config or inactive) | **24** |
| CMS MGMT truststore PUT after Auto-TLS | No (CMS service restart via API) | No | **27** `reconcile_cm_cms_after_autotls.yml` only when truststore PUT **changed** |
| CMS play **29** (psql ensure, REST configure) | **No** | No | `configure_cm_cms_api.yml` restarts CMS only when monitors unhealthy or config drift |

Override: **`cm_scm_server_restart_manager_agent`**: `auto` (default), `always`, or `never` on manager agent restart after scm-server restart in `apply_cm_restart_after_config.yml`.

### CM agent heartbeat recovery (after Auto-TLS / stale heartbeats)

When **all** CM hosts show stale **Last Heartbeat** after playbook **27** or a failed CM restart, bring **CM Server** up first, then restart agents.

**On `cldr-mngr` (SSH):**

```bash
sudo systemctl restart cloudera-scm-server
# Wait until HTTPS API responds (Auto-TLS default port 7183):
curl -sk -u admin:'<cm_admin_pass>' 'https://<cldr-mngr-fqdn>:7183/api/version'
curl -sk -u admin:'<cm_admin_pass>' 'https://<cldr-mngr-fqdn>:7183/api/v59/cm/version'
```

**Cluster-wide agents (Ansible ad-hoc or playbook):**

```bash
cd ansible-playbooks
export ANSIBLE_PRIVATE_KEY=/path/to/sshkey.pem
ansible -i inventory.ini 'all:!ipaserver' -b -m systemd \
  -a 'name=cloudera-scm-agent state=restarted enabled=yes'
```

Or re-run **`reconcile_cm_agents.yml`** / **`27_setup_cm_autotls.yml`** once `/cm/version` is healthy. Playbook **27** restarts CM Server before mass agent reconcile and **fails** if the API is still down (avoids restarting every agent while CM is offline).

Jenkins: set **`cm_autotls_force_run: true`** in **`ANSIBLE_GROUP_VARS_YAML`** and re-run **`CM_TLS_KRB_LDAP`** when you need generateCmca despite CM already reporting Auto-TLS (see `jenkins/README.md`).

### Alignment with cloudera-labs `cm_autotls` / `cm_kerberos` reference pattern

A user-supplied "working" reference playbook pattern (Caddy `proxy_host` CM API, `cloudera.cluster.cm_autotls` / `cm_kerberos` **modules** with `trusted_ca_certs`/`state: present`, restart-then-Caddy-flip order) was compared against `27_setup_cm_autotls.yml` / `30_setup_cm_krbs.yml`. Findings:

| Reference pattern | This repo | Verdict |
|---|---|---|
| `cloudera.cluster.cm_autotls` / `cm_kerberos` **modules** (`state: present`, `trusted_ca_certs`, `kdc_host`) | **These modules do not exist** in the pinned collection (`git+cloudera.cluster.git,v4.4.0` — checked `plugins/modules/*.py`). Only `roles/cloudera_manager/autotls` and `roles/cloudera_manager/kerberos` exist, calling the `cloudera.cluster.cm_api` **action plugin** (`generateCmca` / `importAdminCredentials` — the same CM REST endpoints this repo already calls via `ansible.builtin.uri`), plus a separate `cloudera_manager.config` role dependency. | **Not adopted.** The pasted reference names modules this collection version does not ship; the closest real equivalent (the roles) needs the full Labs `module_defaults`/inventory-group convention the task asked to avoid. Our REST-based flow already implements the same underlying CM API calls the roles wrap. |
| CM API via Caddy `proxy_host` :80 (HTTP→CM :7180, then :7183 after Auto-TLS) | CM/ECS are **not** on Caddy by design (`caddy_vhost_urls.j2` serves portal/pgAdmin/monitoring/IPA only) — direct `https://<cldr-mngr>:7183` / `:7180`. See `.cursor/LEARNINGS.md` and "CM UI hostname" note above. | **Architectural gap, left as-is.** Fronting CM through Caddy would need `cm_config_api_via_caddy_proxy`-style wiring end-to-end (frontend_url, module_defaults host/port) beyond this fix's scope. Flagged for the user — see below. |
| CA bundle on CM host (FreeIPA CA + optional Caddy self-signed) trusted **before** Auto-TLS via `trustedCaCerts` | `auto-tls*.json.j2` already emits `trustedCaCerts` from `use_freeipa_for_crt_mgmt`, but the default was hardcoded `false` regardless of identity provider — FreeIPA deployments silently got **no** IPA CA trust in the Auto-TLS truststore. | **Fixed.** `use_freeipa_for_crt_mgmt` now defaults to `identity_provider_effective == 'freeipa'` and remains overridable through group vars or Jenkins `ANSIBLE_GROUP_VARS_YAML`. New `common_tasks/resolve_cm_autotls_trusted_ca.yml` `stat`s `/etc/ipa/ca.crt` on the CM host first and disables the flag (with a warning) instead of sending generateCmca a path that does not exist. Caddy's self-signed cert is **not** added — Caddy does not front CM here, so there is no matching cert to trust. |
| `auto_tls_changed` → restart agents → restart scm-server (wait `:7183`) → flip Caddy frontend → restart CMS | `27_setup_cm_autotls.yml`: restart scm-server → wait `/cm/version` healthy → restart the CM host's own agent → cluster-wide agent reconcile (`hosts: all:!ipaserver`) → ensure agent truststore (`cm-auto-global_truststore.jks`) → reconcile CMS trust + restart CMS. No Caddy flip (no CM Caddy frontend to flip). | **Kept as-is.** This ordering (server → local agent → cluster agents → truststore → CMS) was hardened across many prior fixes (`fix-cms-truststore-stat`, `fix-autotls-truststore-on-cm`, `cms-trust-respect-autotls-intent`, etc.) for CM's actual truststore-materialization behavior; it is not a straight port of the generic Labs role's handler order and changing it risks reintroducing already-fixed bugs. |
| `cloudera.cluster.cm_kerberos` (`kdc_host`, `kdc_admin_host`, `realm`, IPA `state: present`) | `30_setup_cm_krbs.yml` PUTs `/cm/config` (`KDC_HOST`, `KDC_ADMIN_HOST`, `SECURITY_REALM`, `KDC_TYPE`, `KRB_ENC_TYPES`) then POSTs `/cm/commands/importAdminCredentials` over **HTTPS `:7183`** — same CM API the reference module would call. Traced the "already configured" gates (`kerberos_already_configured`, `cm_kerberos_config_changed`): both force the PUT + restart + import path whenever CM reports `kerberized=false` — **no path skips the import when Kerberos is actually not enabled.** | **No functional gap found**; kept as-is. If `kerberized` still reads `false` after a run, it is almost always one of: KDC port 88 unreachable from the CM host (`preflight_kdc_reachable.yml` fails first), wrong `ipaadmin_password`/`ad_kdc_admin_password`, or `importAdminCredentials` HTTP failure logged in `cloudera-scm-server.log` — see the **`kerberized=false`** troubleshooting row below and `verify_cm_kerberos_enabled.yml`'s fail-fast diagnostics, which print the exact CM API URL, response, and cause to check. |

**Action needed from the user (not implemented here):** `cm_config_api_via_caddy_proxy` and `cm_apply_caddy_frontend_url` already exist in `group_vars/all.yml` but are marked **Deprecated** (`docs/REFERENCE.md`) — CM-behind-Caddy was tried previously and this repo settled on direct `:7180`/`:7183` access instead (see `.cursor/LEARNINGS.md` "CM UI hostname ... is Caddy-only" note). If you still want the reference's Caddy `proxy_host` :80 pattern for CM, that is a deliberate un-deprecation + Caddy vhost/`frontend_url` wiring change, not a bug fix — flag it explicitly and we can scope that separately rather than silently re-enabling a path this codebase already moved away from.

---

## Cleanup runbook

Always requires explicit confirmation:

```bash
ansible-playbook -i inventory.ini 99_cleanup.yml \
  -e cleanup_enabled=true -e cleanup_confirm=true \
  -e <scope_toggle>=true
```

### Common cleanup scopes

```bash
# Stop CMS only
ansible-playbook -i inventory.ini 99_cleanup.yml \
  -e cleanup_enabled=true -e cleanup_confirm=true \
  -e cleanup_stop_cms=true

# Delete base cluster
ansible-playbook -i inventory.ini 99_cleanup.yml \
  -e cleanup_enabled=true -e cleanup_confirm=true \
  -e cleanup_delete_base_cluster=true

# Remove CM, keep PostgreSQL data
ansible-playbook -i inventory.ini 99_cleanup.yml \
  -e cleanup_enabled=true -e cleanup_confirm=true \
  -e cleanup_remove_cm=true -e cleanup_remove_cm_agents=true \
  -e cleanup_stop_postgres=true

# Full end-to-end teardown
ansible-playbook -i inventory.ini 99_cleanup.yml \
  -e cleanup_enabled=true -e cleanup_confirm=true \
  -e cleanup_e2e=true
```

See [REFERENCE.md](REFERENCE.md#cleanup-99_cleanupyml) for all toggles.

### Service-data reset while preserving installation assets

Use `98_cleanup_cluster_services.yml` when rebuilding only the base and/or ECS
clusters. Unlike `99_cleanup.yml`, this workflow preserves CM, agents, packages,
agent host UUIDs, `/opt/cloudera/parcels`, `/opt/cloudera/csd`, parcel caches,
and package repositories.

Preview first:

```bash
cd ansible-playbooks
./cleanup-cluster-services.sh --scope all
```

Execute for `base`, `ecs`, or `all`:

```bash
./cleanup-cluster-services.sh --scope all --execute
```

Direct Ansible execution requires the exact confirmation token:

```bash
ansible-playbook -i inventory.ini 98_cleanup_cluster_services.yml \
  -e cleanup_cluster_services_scope_input=all \
  -e cleanup_cluster_services_execute_input=true \
  -e cleanup_cluster_services_confirm_input=DELETE-CLUSTER-SERVICE-DATA
```

The playbook first submits the selected cluster stop command, polls its CM
command ID to successful completion, deletes the cluster registration, and
requires an explicit follow-up HTTP 404. It then stops the preserved agent,
removes explicitly allowlisted service configuration, data, logs, runtime state,
and discovered service-specific `/tmp` traces, recreates the agent process
directory, and restarts the agent.

Base-node cleanup includes the traditional reinstall-conflict locations
`/hadoop-ozone`, the OM/SCM/Recon metadata leaves below
`/var/lib/hadoop-ozone`, `/impala`, `/hdfs`, `/dfs`, `/hadoop*`, `/yarn*`,
`/var/local/kafka`, `/tmp/.scm_prepare_node.lock`, `/tmp/kafka-logs`, and
generated `/etc` trees for all supported Cloudera services. Wildcard-equivalent
targets are discovered and printed during preview, then removed individually
through `ansible.builtin.file`.

For ECS, this is a destructive rebuild rather than a lightweight runtime reset:
it runs the parcel-shipped `rke2-killall.sh` twice, runs
`rke2-uninstall.sh`, refuses to delete configured ECS storage while it is
mounted, and removes only `ecs_docker_data_path`, `ecs_lso_data_path`, and
`ecs_longhorn_data_path` plus allowlisted RKE2/ECS state, including managed
Docker and containerd library roots. Standalone etcd/k3s library roots outside
the RKE2/Rancher tree are not removed. Parcel and CSD content remain.
PostgreSQL is not modified by base/ECS cleanup. The preserved agent UUID retains
the host identity; it does not recreate deleted clusters or roles.

Base, ECS, and E2E cleanup preserve service-owned `/var/lib` directories by
default. Set `cleanup_remove_service_lib_dirs=true` for playbook 99, or pass
`--remove-service-lib-dirs` to `cleanup-cluster-services.sh`, to remove the
corresponding allowlisted service libraries. PostgreSQL, FreeIPA, and Cloudera
Manager server state remain controlled by their separate cleanup switches.
When `99_cleanup.yml` removes CM (`cleanup_remove_cm=true` or
`cleanup_e2e=true`), CM-only cleanup resets `scm` and `rman`; E2E cleanup,
after successfully stopping/deleting base and ECS clusters, resets every
configured PostgreSQL service database. CM/CMS are stopped and remaining
database sessions are terminated before schemas are reset. Database containers
and login roles are preserved;
tables, sequences, functions, views, extensions, and other schema objects are
removed. ECS cleanup refuses to proceed while configured storage or managed
container-runtime `/var/lib` paths are mounted. The E2E path removes CM
server/agent packages, supervisor state, CSDs, parcels, parcel repositories, and
cluster-node service state. Even with `cleanup_e2e=true`, PostgreSQL data and
packages are preserved unless the separate `cleanup_remove_postgres_*` toggles
are explicitly enabled.

### Manual PostgreSQL reset of the CM `scm` schema

Service-only reset (`98_cleanup_cluster_services.yml`) **does not** change the
CM PostgreSQL database. Use the steps below when you need an empty `scm` schema
so Cloudera Manager can be re-initialized (for example after a failed first
install or before re-running `scm_prepare_database.sh` / playbook **24**) while
keeping CM packages, agents, parcels, and CSDs on the nodes.

**When to use this (partial / CM DB only) vs full cleanup (`99_cleanup.yml`):**

| Goal | Approach |
|---|---|
| Rebuild base/ECS clusters only; keep CM DB and CM state | `98_cleanup_cluster_services.yml` (no PostgreSQL changes) |
| Wipe CM (and Reports Manager) DB schemas; optionally uninstall CM | `99_cleanup.yml` with `cleanup_remove_cm=true` or `cleanup_e2e=true` and `cleanup_reset_service_databases=true` (default) — see [REFERENCE.md](REFERENCE.md#cleanup-99_cleanupyml) |
| Wipe only the `scm` schema inside the existing `scm` database; CM still installed | Manual SQL below (or CM-only **99** scope above) |

**Warnings:**

- **Destructive** — removes all tables and other objects in the `scm` schema.
  CM configuration, cluster metadata, and wizard state in that schema are lost.
- **Stop Cloudera Manager** — stop `cloudera-scm-server` and CMS
  (`cloudera-scm-headlamp` / Reports Manager) before running SQL so no sessions
  hold locks on `scm` objects.
- **Backup** — dump the database or schema if you might need to recover
  (`pg_dump -Fc -n scm …` or a snapshot of the PostgreSQL data directory).
- **Permissions** — connect as a role that can drop objects in the `scm` schema
  (typically the `scm` database owner or PostgreSQL superuser). Defaults:
  database `scm`, owner `scm` (`group_vars/all.yml`).

Connect to the CM database on the PostgreSQL host (see portal **Database &
pgAdmin** or `postgres_host_fqdn` / `postgres_port` in inventory), then run
**one** of:

**Option 1 — drop each table in the `scm` schema:**

```sql
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'scm') LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
END $$;
```

**Option 2 — drop and recreate the schema (simpler):**

```sql
DROP SCHEMA scm CASCADE;
CREATE SCHEMA scm;
```

After reset, grant ownership on the new schema to the CM DB user if you used
Option 2 (`GRANT ALL ON SCHEMA scm TO scm;` / `ALTER SCHEMA scm OWNER TO scm;`
when your install expects the `scm` role to own the schema). Restart
`cloudera-scm-server`, then re-run CM database preparation and the CM playbooks
(**23**–**24**) as needed.

---

## Troubleshooting

**FreeIPA `ipa-server-install` `FileNotFoundError` [Errno 2] — diagnostic bundle (run on ipaserver as root, paste output):**

```bash
{
  echo "=== $(date -Is) $(hostname -f) ==="
  ipactl status || true
  hostname -f; hostname -s; getent hosts "$(hostname -f)" || true
  command -v host dig ipa-server-install || true
  rpm -qa 'ipa*' '389-ds*' bind-utils openldap 2>/dev/null | sort
  ls -la /etc/ipa /var/lib/ipa /var/lib/ipa/sysrestore /var/lib/ipa/sysupgrade 2>/dev/null || true
  ls -la /etc/dirsrv/ /etc/openldap/ldap.conf 2>/dev/null || true
  grep -nE 'FileNotFoundError|ipachangeconf|newConf|install_check' /var/log/ipaserver-install.log 2>/dev/null | tail -25
  tail -n 60 /var/log/ipaserver-install.log 2>/dev/null || true
} | tee /tmp/ipa-install-debug.txt
```

| Issue | Action |
|---|---|
| **RHEL package install fails after DNS update** (`Could not resolve host: rhui.<region>.aws.ce.redhat.com`) | The client resolver points to FreeIPA first, but IPA forwarding to the AWS VPC resolver is not healthy. Current automation installs identity-client packages before DNS cutover, reconciles `ipa dnsconfig-mod --forwarder=<vpc-dns> --forward-policy=first`, and waits for the regional RHUI name to resolve before enrollment. It reapplies and verifies managed DNS after both server and client installers, because IPA/realm tools may modify resolver settings. On RHEL 8/9, `/etc/NetworkManager/conf.d/90-cldr-managed-dns.conf` makes NetworkManager leave `/etc/resolv.conf` under Ansible control; `/etc/sysconfig/network` is intentionally unused because it is not authoritative. Re-run the full **IDENTITY** stage so playbook **12** repairs the IPA forwarder before **13/16**. On ipaserver verify `ipa dnsconfig-show --all --raw` and `dig +short @127.0.0.1 rhui.<region>.aws.ce.redhat.com A`. |
| Wrong identity detected | Run `detect_identity.yml`; set `identity_provider: freeipa` or `ad` to override |
| **FreeIPA partial install** (`ipactl status` → **IPA is not configured** / rc=4; `default.conf` missing but **`/var/lib/ipa`** has **`sysrestore.index`** / **`sysrestore.state`** or install dies with **`FileNotFoundError` [Errno 2]** on **`sysupgrade.state`**, **`/etc/ipa/custodia/custodia.conf`**, or other config paths; or empty **`/var/lib/ipa`** without **`sysrestore.state`**; or `/etc/dirsrv/slapd-*` remains; interactive `ipa-server-install --uninstall` defaults to **no**) | See **Manual `ipa-server-install` after a failed run** under Scenario A (one-liner **`mkdir -p /etc/ipa/custodia .../sysupgrade`** after **`rm -rf`**). On **ipaserver** as **root**: unattended uninstall, then **`rm -rf /var/lib/ipa /etc/ipa`** and **`/etc/dirsrv/slapd-*`** when **`ipactl`** is still not configured. Automation: **`ipa_deep_recovery.yml`** with **`ipa_server_deep_recovery: true`**, then **`12_setup_freeipa_server.yml`** (preflight + **`ipa-server-install`**). Optional: **`-e ipa_server_uninstall_force=true`**. |
| **LDAP port 389/636 in use** (`ipa-server-install`: port 389 already in use; playbook **12** preflight fails while **`ipactl`** not configured) | Leftover **`dirsrv`** / **`/etc/dirsrv/slapd-*`** from partial install. See **Port 389 / 636 conflict** under Scenario A (`ss -tlnp`, stop **`dirsrv@*`**, **`rm -rf /etc/dirsrv/slapd-*`** when not configured). Then **`12b`** + **`12`**. |
| **`ipa-client-install` failed** on one host (Jenkins **IDENTITY** / playbook **16**; task censored by `no_log`; `changed: false`) | Host lacks `/etc/ipa/default.conf` while peers skip (already enrolled). Typical on **new ECS/base workers**: re-run phase **1** (`02_set_hostname.yml`, `03_create_etc_hosts.yml` on **all** hosts), then **`14_setup_dns_records.yml`**, then **`16_setup_identity_client.yml`** (or `--limit pvcecs-workerN`). On the host: `hostname -f`, `getent hosts $(hostname -f)`, `getent hosts ipaserver.<domain>`, `tail -50 /var/log/ipaclient-install.log`. Playbook **16** fails with redacted stderr + log tail when install rc≠0; partial debris triggers **`ipa-client-install --uninstall --unattended`** before retry (see recovery steps under **`zlib.error`**). |
| **`Fail with Kerberos kinit diagnostics`** on one client (Jenkins **IDENTITY** / **`join_freeipa_client.yml`**; admin **`kinit` task `no_log`**) | Install was **skipped** (`/etc/ipa/default.conf` present) or finished earlier in the play; both host keytab and admin **`kinit` returned rc≠0**. On the host as **root**: `export KRB5CCNAME=FILE:{{ ipa_kerberos_ccache_path }}` (default **`/root/.ansible-ipa-krb5cc`**); `klist`; `test -f /etc/ipa/default.conf`; `getent hosts ipaserver.<domain>`; `chronyc tracking`; `kinit -k -t /etc/krb5.keytab host/$(hostname -f)@<REALM>`; if needed `kinit admin` (password = **`ipaadmin_password`** / Jenkins **`ANSIBLE_GROUP_VARS_YAML`**); then `ipa ping`. Re-run **`16_setup_identity_client.yml --limit <host>`**. |
| **`zlib.error`** / **`invalid code lengths set`** during **`ipa-client-install`** schema RPC (`https://ipaserver.<domain>/ipa/json`) | **Cluster-wide on ipaserver**, not worker-specific — older workers already enrolled skip install. Fix **`zz-ipa-caddy-proxy.conf`** (no **`mod_substitute`** on **`/ipa/json`**); **`systemctl reload httpd`** on ipaserver; verify gzip from the worker (`curl` block above); re-run **PORTAL** then **`16_setup_identity_client.yml --limit <host>`**. Uninstall on the worker only if partial **`/var/lib/ipa-client/sysrestore`** or **`/etc/ipa`** debris remains without **`default.conf`**. |
| **FreeIPA client partial install** (`default.conf` missing; **`sysrestore.index`** / **`sysrestore.state`** or deployment-specific **`/etc/ipa/ca.crt`** remains; retry says *already configured*) | On worker: **`ipa-client-install --uninstall --unattended`** when sysrestore markers exist (or re-run playbook **16**, which detects them via **`detect_ipa_client_install_state.yml`**). Ordinary package-created `/etc/ipa` entries do not trigger uninstall. Server-side **`sanitize_ipa_paths_before_fresh_install.yml`** applies to **ipaserver** playbook **12** only, not clients. |
| Stale `default.conf` (`ipactl` rc=4 / "IPA is not configured", install was skipped) | Playbook **12** removes lone stale `/etc/ipa/default.conf` when no partial debris, then runs `ipa-server-install`. Unattended uninstall is limited to forced or confirmed partial/broken states; it is skipped on healthy configured IPA and clean new hosts. Manual: `rm -f /etc/ipa/default.conf` only if `ipactl status` shows not configured and there is no `/etc/ipa/ca.crt` / DS data; then re-run playbook **12**. |
| FreeIPA configured but stopped (`default.conf` present, `ipactl` healthy, services not RUNNING) | Playbook **12** skips `ipa-server-install` and runs `ensure_ipa_kdc_services.yml` (`systemctl start ipa`, then `ipactl start` if needed). Manual: `systemctl start ipa` or `ipactl start` on ipaserver. |
| CM Kerberos/KDC not enabled (`kerberized=false`) | Playbook **30** waits up to `cm_krb_kerberized_wait_retries × cm_krb_kerberized_wait_delay` (default 300s) then fails with `kerberosInfo` details. **FreeIPA:** on ipaserver `ipactl status` (krb5kdc RUNNING); re-run `12_setup_freeipa_server.yml` then `30_setup_cm_krbs.yml`. **AD:** set `ad_kdc_host` (not empty). **CM:** confirm `importAdminCredentials` in `cloudera-scm-server.log`; Kerberos REST must use HTTPS `:7183` when Auto-TLS is on. **Manual UI:** Administration → Settings → Kerberos — set realm, KDC type/host, import Account Manager principal/password, Save, restart CM Server. |
| CM Kerberos UI warns on **rc4-hmac** / weak crypto | Set `krb5_enc_types` to `aes256-cts aes128-cts` (default). Re-run `12` + `30`; regenerate Kerberos credentials in CM. See **Kerberos encryption types (AES)** above. |
| **ZooKeeper has 0 Servers** (Stop Cluster / Deploy Client Config after KDC) | ZK **service** exists but no **Server** roles — common on clusters created before host template `service: ZOOKEEPER` fix or when **31** skipped create. Add **Server** on `base-workers` in CM, or delete base cluster and re-run **31**. See **ZooKeeper placement** under step 7. Kerberos enablement (`30_setup_cm_krbs.yml` / manual KDC) is separate; fix ZK roles first. **Stop Cluster** can remain blocked until ZK has at least one Server role. |
| CM **Hosts** — **Last Heartbeat** stale (~minutes), all **Commissioned** | **Agent → CM Server** path (heartbeat is not Host Monitor). Check `cloudera-scm-agent`, `server_host` FQDN, `use_tls` after **27**, SG **7182/7183** agent→manager. Re-run **`reconcile_cm_agents.yml`** or **27** (agent reconcile play). Chrony: **07_prereq_setup_002.yml**. |
| CM **Hosts** — **Tags** empty | Expected until tags are set (automation: **28** with `cm_host_tags_enabled`, or CM UI). |
| CM **Hosts** — load/disk/memory sparse | **Host Monitor** (CMS). Re-run **29** when Service Monitor / Host Monitor unhealthy; see REFERENCE CMS troubleshooting. |
| DNS not persisting on Ubuntu | DNS is applied via netplan — see [REFERENCE.md](REFERENCE.md#dns-configuration) |
| CM install fails on Ubuntu | Set `cm_repo_username` / `cm_repo_password`; use `cm_repo_source: public` or `internal` (apt mirror on cldr-mngr) |
| CDH parcel download fails | Ensure worker facts exist (run phase 1 first). Set `cdh_parcel_os_suffix: noble` or `jammy` for Ubuntu workers, `el8`/`el9` for RHEL |
| PostgreSQL listens on 127.0.0.1 only | Re-run `23_setup_postgres.yml` (uses `pg_ctlcluster restart` on Ubuntu) or `pg_ctlcluster 18 main restart` |
| SSH restart fails on Ubuntu | Fixed in `00_setup_ssh_preqs.yml` — uses `ssh` service instead of `sshd` |
| AWS vs bare metal DNS wrong | Set `deployment_environment: aws` or `baremetal` explicitly |
| IPA external DNS / forwarders wrong on AWS | Default **`dns_forwarders: no`** uses **VPC `--forwarder`** on fresh **`ipa-server-install`** (via **`set_dns_facts`** + **`resolve_ipa_install_dns_forwarders`**). Existing servers skip install but playbook **12** runs **`ipa dnsconfig-mod`** when VPC mode applies. Force **`--no-forwarders`**: **`dns_forwarders: no-forwarders`** or **`ipa_server_install_use_vpc_dns_forwarder: false`**. |
| NetworkManager restart failed | Fixed in `03_create_etc_hosts.yml` — pull latest `main` |

---

## Quick reference — playbook order

```
00        SSH prerequisites (00_setup_ssh_preqs.yml)
01-09     OS prerequisites
10        Deployment portal bootstrap
11        Identity router (FreeIPA or AD, auto-detected)
12-19     FreeIPA/AD server, DNS, network, client, wildcard
20-24     CM repos/install + PostgreSQL + CM server/agents
25        Verify CM
26        CM license
27-30     Auto-TLS, CMS, LDAP, Kerberos
31        Base cluster; rechecks Auto-TLS and converges cluster Kerberos
32        Monitoring stack
33-34     ECS cluster + data services
35        Portal refresh
36-37     EC2 start/stop automation (ipaserver)
99        Cleanup (destructive)
```

See [`RUN_ORDER.md`](RUN_ORDER.md) for the full sequential index and Jenkins stage mapping.

### Migration: renumbered/de-numbered playbooks (2026-09)

Four playbooks that duplicated another playbook's numeric prefix (`00_*` had three files, `25_*` had two, and `12_*`/`12b_*` collided/sorted unpredictably) were renamed. None of them own a distinct mainline `pvc_setup.sh` sequence slot — they are either always-imported helpers or optional/manual tools — so they were de-numbered instead of assigned a new number. This is a rename only; no task logic changed.

| Old filename | New filename | Notes |
|---|---|---|
| `00_ensure_collections.yml` | `ensure_collections.yml` | Imported by every numbered playbook; still runnable standalone |
| `00_detect_identity.yml` | `detect_identity.yml` | Still runs immediately before `11_identity_setup.yml` in `pvc_setup.sh` phase 2 |
| `12b_ipa_deep_recovery.yml` | `ipa_deep_recovery.yml` | Optional recovery helper before playbook **12**; unchanged behavior/vars (`ipa_server_deep_recovery`) |
| `25_reconcile_cm_agents.yml` | `reconcile_cm_agents.yml` | Optional agent reconcile helper; unchanged behavior/vars |

If you have scripts, cron jobs, or forks that invoke any of the old filenames directly (`ansible-playbook -i inventory.ini 00_detect_identity.yml`, etc.), update them to the new filename — `pvc_setup.sh`, Jenkins, and every in-repo doc/reference were updated in the same commit. See [`RUN_ORDER.md` → Migration: renumbering duplicate prefixes](RUN_ORDER.md#migration-renumbering-duplicate-prefixes-2026-09) for the full rationale.
