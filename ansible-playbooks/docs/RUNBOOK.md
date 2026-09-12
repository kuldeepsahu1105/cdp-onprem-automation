# Runbook — How to Use

Step-by-step guide for deploying and tearing down Cloudera Private Cloud with these Ansible playbooks.

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
| **Single playbook** | `./run-playbook.sh 10_setup_deployment_portal.yml` **or** `ansible-playbook …` (each playbook imports `00_ensure_collections.yml`) **or** once manually: `ansible-galaxy collection install -r requirements.yml` |

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

### Service URL verification (portal stack + Cloudera Manager)

Printed URLs live in `CDP_ACCESS_URLS_*` / `jenkins/artifacts/access-urls.txt`.

**Cloudera Manager (`25_verify_cm.yml`):**

- **Required (manager-local):** HTTP/HTTPS UI on `cldr-mngr` via `probe_cm_manager_ui_http.yml` (private IP / `ansible_host` / FQDN, then loopback) and Auto-TLS HTTPS on the same bind address — **fails** the play if CM is down. CM API setup (`set_cm_api_url.yml`) prints `cm_api_url` and probes from Jenkins with delegation per `#57`.
- **External from controller:** Only when `deployment_portal_enabled: false` **and** `deployment_portal_verify_tier_b_enabled: true` (default **false**). With the portal stack enabled, external CM URL warns run from `10_setup` / `35_refresh` on the controller (milestone-scoped), not again in `25_verify_cm`.

**Portal / monitoring / IPA / ECS** use the tier labels below on the ops host and Ansible controller:

| Tier | Where it runs | What it checks | On failure |
|---|---|---|---|
| **A (required)** | **Ops host** (`ipaserver`): `http://127.0.0.1:<deployment_portal_http_port>/`, Caddy **Host** vhosts scoped by **`deployment_portal_verify_milestones`** (bootstrap **portal** + **ipa** only; **cm** / **cm_tls** / **monitoring** / **ecs** after each deploy phase). CM milestone UI on `cldr-mngr` runs in portal refresh verify, not via Caddy | Local service health | **Fail** the play for milestones in the active list |
| **B (external)** | Ansible **controller** when `ansible_control_reachability_effective` is **`public`** | HTTP GET printed **external** URLs (portal/pgAdmin/Grafana Caddy vhosts, CM FQDN + public IP direct ports, IPA, ECS console) via `verify_service_urls_from_controller.yml` | **`deployment_external_url_verify`** (default **`warn`**) or per-service overrides — `warn`, `fail`, or `skip` |

**When portal verify runs:** After `10_setup_deployment_portal.yml` / `35_refresh_deployment_portal.yml` (`verify_deployment_portal_caddy.yml`). Jenkins **PORTAL** reruns get optional Tier **B** warns for printed URLs when security groups allow; manager-local portal/CM checks are separate as above.

### Portal URL verify milestones (by deploy stage)

| Stage / trigger | `deployment_portal_verify_milestones` (cumulative) | Tier **A** Caddy vhosts / host checks | Tier **B** (controller, when public reach) |
|---|---|---|---|
| **PORTAL** (`10_setup_deployment_portal.yml`) | `portal`, `ipa` | Portal index, portal + IPA vhosts (required when IPA in inventory); **no** pgAdmin or CM Caddy vhost probes | Portal (+ IPA when in list); **no** pgAdmin Tier **B** until milestone `pgadmin` |
| **PORTAL pgAdmin hard gate** (optional refresh) | + `pgadmin` | + pgAdmin Caddy vhost required | + pgAdmin external |
| **IDENTITY** (phase 2 refresh) | + `identity` | Same as PORTAL | + FreeIPA printed / Caddy IPA URLs |
| **CM_INSTALL** | — | — | CM `frontend_url` via `26_setup_cm_license.yml` (direct FQDN); **no** `35_refresh` |
| **CM_TLS** (first `35_refresh` after CM) | + `cm`, `cm_tls` | CM UI on cldr-mngr `:7180`/`:7183` (`probe_cm_manager_ui_http.yml`) | + CM HTTP FQDN + public IP `:7180`; + CM HTTPS FQDN `:7183` |
| **CDH** (phase `cdh` refresh) | + `cdh` | (index refresh; no extra vhosts) | (no new probes) |
| **MONITORING** | + `monitoring` | + Grafana / Prometheus vhosts | + Grafana / Prometheus external |
| **ECS** | + `ecs` | (no Caddy — ECS not on portal stack) | + ECS console / gateway URLs (`console_hint`) |

Set explicitly: `-e deployment_portal_verify_milestones=cm,cm_tls`. `pvc_setup.sh` runs `35_refresh` on `DEPLOY_PHASE=portal_refresh` (or when `DEPLOYMENT_PORTAL_REFRESH=true`). Legacy `deployment_portal_verify_post_cm: true` on `35_refresh` implies **`portal`, `ipa`** when milestones are omitted (not `cm` — add `cm` via `-e` or a portal refresh with the desired milestone list).

Variables:

- `deployment_external_url_verify` — global Tier **B** mode (`warn` \| `fail` \| `skip`; default `warn`; Jenkins sets `warn`)
- `deployment_portal_external_url_verify` — legacy alias when global unset
- `deployment_cm_external_url_verify`, `deployment_grafana_external_url_verify`, … — per-service overrides
- `deployment_service_external_url_verify` — optional map `{ cm: warn, grafana: skip, … }`
- `deployment_portal_verify_milestones` — list or comma string (`portal`, `ipa`, `pgadmin`, `identity`, `cm`, `cm_tls`, `cdh`, `monitoring`, `ecs`); default `[]` in `group_vars`; bootstrap play sets `portal` + `ipa` (not `pgadmin` — avoids failing PORTAL on pgAdmin 502 while the container is still starting)
- `deployment_portal_url_verify_skip_vpc` — skip hard-fail on VPC-only printed URLs when control is public-only (Jenkins sets `true`)
- `ansible_control_reachability` — must be `public` (or auto → public on Jenkins) for Tier **B**

If Tier **B** warns but Tier **A** passed, open security groups for the relevant ports (**81** (`deployment_portal_http_port`), **5050**, **7180**/**7183**, etc.) from Jenkins/office CIDRs. Grep Ansible logs for `Tier B` or `CDP_ACCESS_URLS_BEGIN`; `jenkins/scripts/build-access-urls.sh` lists URLs for email.

**Caddy still on legacy :8088 in `docker ps`:** `deployment_portal_docker-compose.yml.j2` binds `0.0.0.0:{{ deployment_portal_http_port }}` (repo default **81** since group_vars moved off 8088). An ops host that was provisioned earlier keeps the old publish until compose is re-rendered and Caddy is recreated — `docker compose up -d` alone does not remapping ports. Fix: re-run Jenkins **PORTAL** (play 10/35 re-templates compose and `--force-recreate caddy` when the file changes) or on **ipaserver**: `cd /opt/cldr-deployment-portal && docker compose up -d --force-recreate caddy`. Confirm with `curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:81/`.

**Monitoring containers with no host ports:** Grafana, Prometheus, and Alertmanager are **by design** not published on the host; only **cAdvisor** uses **8089** (`monitoring_cadvisor_host_port`). Use Caddy on port **81** (`/grafana/`, `/prometheus/`, `/alertmanager/`) or per-service Caddy vhosts when `caddy_vhost_enabled` is true.

**pgAdmin 502 / :5050 unreachable:** On **ipaserver** (or portal host), `cd {{ deployment_portal_config_dir | default('/opt/cldr-deployment-portal') }}` then `docker ps -a --filter name=cldr-portal-pgadmin` and `curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:5050/`. Caddy must reverse-proxy **`pgadmin:80`** (compose service name). Fix: re-run Jenkins **PORTAL** or `docker compose -f docker-compose.yml up -d --force-recreate pgadmin caddy`. Ansible task `verify_deployment_portal_pgadmin.yml` fails with `docker logs` on error; set `deployment_portal_pgadmin_debug_logs: true` for extra log output after a successful sync.

**pgAdmin restart loop / invalid email:** pgAdmin 8 rejects `PGADMIN_DEFAULT_EMAIL` values like `admin@cldrsetup.local` (from `admin@{{ cluster_domain }}`). Set `pgadmin_default_email` to a real TLD (default `admin@pvc.cloudera-labs.com`), re-render compose, then on the portal host: `cd /opt/cldr-deployment-portal && docker compose up -d --force-recreate pgadmin`.

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

### 3. Detect identity provider

```bash
ansible-playbook -i inventory.ini 00_detect_identity.yml
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
ansible-playbook -i inventory.ini 24_start_cm.yml
ansible-playbook -i inventory.ini 25_verify_cm.yml
ansible-playbook -i inventory.ini 26_setup_cm_license.yml
ansible-playbook -i inventory.ini 27_setup_cm_autotls.yml
# CM API probes: VPC private_ip from Jenkins (not same-host public EIP); manager IP/FQDN on cldr-mngr. SG must allow 7180/7183 from Jenkins to private IPs.
ansible-playbook -i inventory.ini 28_setup_cm_krbs.yml
ansible-playbook -i inventory.ini 30_setup_cm_ldap.yml
```

If `cm_admin_pass` is not the factory password (`cm_admin_bootstrap_pass`, default `admin`), `25_verify_cm.yml` and later playbooks reset the CM `admin` user to `cm_admin_pass` via the API on first successful connection.

CSD JARs for DataViz / NiFi / NiFi Registry are built from `cdv_version`, `cfm_version`, and related vars during `24_start_cm.yml` (RHEL CM). Set e.g. `cdv_version: "8.1.5"` and update `cdv_dataviz_csd_jar` to match the archive jar name, or pass explicit `scm_csds` URLs.

### 7. Run Phase 4 (CMS + base cluster)

```bash
ansible-playbook -i inventory.ini 29_setup_cm_cms.yml
ansible-playbook -i inventory.ini 31_setup_base_cluster.yml
ansible-playbook -i inventory.ini 33_setup_ecs_cluster.yml
```

`31_setup_base_cluster.yml` builds the cluster from `templates/base_cluster_cluster_spec.j2`. Toggle services with `base_cluster_install_services` in `group_vars/all.yml` or Jenkins `ANSIBLE_GROUP_VARS_YAML` (allowed key `base_cluster_install_services`). Cluster **create** runs only when the cluster does not exist in CM; adding services to an existing cluster requires CM UI/API changes.

`33_setup_ecs_cluster.yml` is skipped automatically when `[ecs-masters]` / `[ecs-workers]` are empty (`ecs_deploy_enabled: auto`).

### 8. Deployment portal (optional)

```bash
ansible-playbook -i inventory.ini 10_setup_deployment_portal.yml
# Optional monitoring (or set monitoring_stack_enabled: true in all.yml for playbook 28)
MONITORING_STACK_ENABLED=true ansible-playbook -i inventory.ini 32_setup_monitoring_stack.yml
```

Ops stack runs on **ipaserver** when present (`deployment_portal_host_group: auto`), else **cldr-mngr**.

**AWS (public IP):** Jenkins and browsers on the internet use `http://<ops-public-ip>:81/`; hosts inside the VPC can use `http://<ops-private-ip>:81/`. The generated index lists both. Caddy vhost URLs use a **dashed** ops public IP in the hostname (`portal.52-221-251-41.pvc.cloudera-labs.com`, not dotted); that requires wildcard DNS on `caddy_vhost_public_base` or use `caddy_vhost_dns_mode: classic_nipio`. Playbook 28 fails fast if Caddy does not respond on `http://127.0.0.1:<deployment_portal_http_port> (default 81)/` on the ops host.

**Caddy FreeIPA vhost:** When `[ipaserver]` is present, `http://ipa.<ops-ip-dashed>.<base>:81/` redirects `/` to **`/ipa/modern-ui/`** (default landing) and reverse-proxies **HTTP** to `<ipaserver-fqdn>` for **`/ipa/modern-ui/`** and **`/ipa/ui`** with **`header_up Host`** and path-matched **`header_up Referer`** (cloudera-labs/openshift pattern). Tier A checks accept **301** on `/` and **200/301** on both UI paths; on `ipaserver`, Ansible verifies `/ipa/modern-ui/` and `/ipa/ui` with matching Referer headers.

**Cloudera Manager (not via Caddy):** Use direct **`https://<cldr-mngr-fqdn>:7183`** (or `:7180` before Auto-TLS) from browsers and Jenkins Tier **B**. Caddy on the ops host serves portal, pgAdmin, monitoring, and IPA only. Optional `cm_external_url` sets a custom published CM URL in portal facts; it does not configure Caddy.

**ECS console (not via Caddy):** Published console URL is **`https://console.<ecs_app_domain>`** (`ecs_control_plane_url_effective`). Override with `ecs_control_plane_url` when needed. Internal ECS **`ApplicationDomain`** stays `ecs_app_domain`.

**Bare metal / private network (no public IP):** Set `deployment_environment: baremetal` (or `deployment_portal_access_profile: private`). The portal index shows only private-network URLs — typically `http://<ops-fqdn>:81/` when `deployment_portal_prefer_fqdn_urls: true`, or `http://<management-ip>:81/` otherwise. pgAdmin stays on port `5050` on the same ops host; database is **cldr-mngr** PostgreSQL. Caddy lab hostnames use the ops management IP (often `caddy_vhost_dns_mode: flat` with IPA/AD DNS).

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
ansible-playbook -i inventory.ini 00_detect_identity.yml
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
ansible-playbook -i inventory.ini 28_setup_cm_krbs.yml
ansible-playbook -i inventory.ini 30_setup_cm_ldap.yml
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
cm_version: "7.13.2.10000"
instance_groups:
  cldr_mngr:
    count: 1
    instance_type: m5.4xlarge
    volume_size: 300
```

See repo root `.tfvars.yaml` for the full template.

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

---

## Troubleshooting

| Issue | Action |
|---|---|
| Wrong identity detected | Run `00_detect_identity.yml`; set `identity_provider: freeipa` or `ad` to override |
| DNS not persisting on Ubuntu | DNS is applied via netplan — see [REFERENCE.md](REFERENCE.md#dns-configuration) |
| CM install fails on Ubuntu | Set `cm_repo_username` / `cm_repo_password`; use `cm_repo_source: public` or `internal` (apt mirror on cldr-mngr) |
| CDH parcel download fails | Ensure worker facts exist (run phase 1 first). Set `cdh_parcel_os_suffix: noble` or `jammy` for Ubuntu workers, `el8`/`el9` for RHEL |
| PostgreSQL listens on 127.0.0.1 only | Re-run `23_setup_postgres.yml` (uses `pg_ctlcluster restart` on Ubuntu) or `pg_ctlcluster 18 main restart` |
| SSH restart fails on Ubuntu | Fixed in `00_setup_ssh_preqs.yml` — uses `ssh` service instead of `sshd` |
| AWS vs bare metal DNS wrong | Set `deployment_environment: aws` or `baremetal` explicitly |
| NetworkManager restart failed | Fixed in `03_create_etc_hosts.yml` — pull latest `main` |

---

## Quick reference — playbook order

```
00-09  Prerequisites
11_identity_setup  Identity + DNS (auto FreeIPA or AD)
16-21  CM install + license
22     Auto-TLS
23-25  Kerberos + LDAP
24     CMS (Management Service)
26     Base cluster (HDFS/YARN/ZK)
99     Cleanup (destructive)
```
