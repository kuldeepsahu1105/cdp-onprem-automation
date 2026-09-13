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

### Why FreeIPA install fails after lab re-runs (playbook 12)

Playbook **`12_setup_freeipa_server.yml`** (via **`11_identity_setup`**) probes **`ipa --version`** (installed/working CLI — not **`ipa-server-install --version`**, which is only the installer RPM, and not **`ipactl --version`**, which is not a valid command; use **`ipactl status`** for service state), **`ipactl status`**, and **`/etc/ipa/default.conf`**, then skips **`ipa-server-install`** only when all three indicate a configured healthy server (**`ipa --version`** rc=0 without **not configured** in output, **`default.conf`** present, **`ipactl`** rc=0 without **IPA is not configured**). If any check fails, it runs preflight (**`mkdir`** under **`/etc/ipa`** + **`ipa_server_etc_ipa_subdirs`** (e.g. **`/etc/ipa/custodia`**), **`/var/lib/ipa`** + **`ipa_server_var_lib_subdirs`**, **`/var/log/ipa`**, plus hostname/DNS asserts) and **`ipa-server-install --unattended`** with VPC **`--forwarder=`** or **`--no-forwarders`** per **`resolve_ipa_install_dns_forwarders.yml`**. Set **`ipa_server_install_force: true`** to re-run install on an already-healthy host (rare; not **`ipa-server-install --force`**). Repeated partial installs can leave broken state; use **`12b_ipa_deep_recovery.yml`** or manual cleanup before re-running identity.

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

For automated debris cleanup before install, run **`ansible-playbook -i inventory.ini 12b_ipa_deep_recovery.yml -e ipa_server_deep_recovery=true --limit ipaserver`**, then re-run **`ansible-playbook -i inventory.ini 12_setup_freeipa_server.yml --limit ipaserver`** (vars supply passwords and forwarders).

**IPA DNS forwarders:** Default **`dns_forwarders: no`** uses the **AWS VPC resolver** (`--forwarder=x.y.0.2` from the instance private IP) on EC2 when **`ipa_server_install_use_vpc_dns_forwarder: true`** (default). On bare metal, or when the VPC resolver cannot be computed, install falls back to **`--no-forwarders`**. Force **`--no-forwarders`**: set **`dns_forwarders: no-forwarders`** or **`ipa_server_install_use_vpc_dns_forwarder: false`**. Skipped installs (healthy **`ipactl`** + **`default.conf`**) get **`ipa dnsconfig-mod`** toward the VPC resolver when VPC mode applies.

**Jenkins IDENTITY / playbook 12:** The **Assert AWS VPC DNS forwarder** task runs only when **`ipa_install_dns_use_vpc_forwarder`** is true (after **`resolve_ipa_install_dns_forwarders`**). If that assert is **skipped** on AWS, install is using **`--no-forwarders`** because the VPC resolver was empty or VPC mode was opted out — check the **Log IPA install DNS forwarder mode** debug line in the job log. **`ipa-server-install` failures** should print **`stderr`** and **`/var/log/ipaserver-install.log`** tail in the **Fail with ipa-server-install diagnostics** task (passwords are not logged; credentials are passed via environment variables).

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
ansible-playbook -i inventory.ini 29_setup_cm_cms.yml
ansible-playbook -i inventory.ini 30_setup_cm_ldap.yml
ansible-playbook -i inventory.ini 28_setup_cm_krbs.yml
```

**Kerberos encryption types (AES):** Defaults use **AES only** (`krb5_enc_types`: `aes256-cts aes128-cts` in CM; FreeIPA KDC via `/etc/krb5.conf.d/cldr-permitted-enctypes.conf`). RC4 is omitted because Java 17+ and Cloudera recommend AES. Do **not** set `allow_weak_crypto=true` unless you explicitly opt in with `krb5_allow_weak_rc4: true` in group_vars.

**Existing deployments** that already show `rc4-hmac` in the CM Kerberos wizard:

1. Re-run `12_setup_freeipa_server.yml` (or at least the ipaserver play in `28_setup_cm_krbs.yml`) to apply the IPA KDC snippet and restart `krb5kdc`.
2. Re-run `28_setup_cm_krbs.yml` — it reconciles `KRB_ENC_TYPES` via the CM API even when `kerberized=true` (may restart Cloudera Manager).
3. In CM, **regenerate** cluster/service keytabs/principals so new keys use AES (CM Kerberos wizard or cluster Kerberos enablement flow). Principals created under RC4-default KDC settings may retain RC4 long-term keys until regenerated.

If `cm_admin_pass` is not the factory password (`cm_admin_bootstrap_pass`, default `admin`), `25_verify_cm.yml` and later playbooks reset the CM `admin` user to `cm_admin_pass` via the API on first successful connection.

CSD JARs for DataViz / NiFi / NiFi Registry are built from `cdv_version`, `cfm_version`, and related vars during `24_start_cm.yml` (RHEL CM). Set e.g. `cdv_version: "8.1.5"` and update `cdv_dataviz_csd_jar` to match the archive jar name, or pass explicit `scm_csds` URLs.

### 7. Run Phase 4 (CMS + base cluster)

```bash
ansible-playbook -i inventory.ini 29_setup_cm_cms.yml
ansible-playbook -i inventory.ini 31_setup_base_cluster.yml
ansible-playbook -i inventory.ini 33_setup_ecs_cluster.yml
```

`31_setup_base_cluster.yml` builds the cluster from `templates/base_cluster_cluster_spec.j2`. Toggle services with `base_cluster_install_services` in `group_vars/all.yml` or Jenkins `ANSIBLE_GROUP_VARS_YAML` (allowed key `base_cluster_install_services`). Cluster **create** runs only when the cluster does not exist in CM; adding services to an existing cluster requires CM UI/API changes.

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

**AWS (public IP):** Jenkins and browsers on the internet use `http://<ops-public-ip>:81/`; hosts inside the VPC can use `http://<ops-private-ip>:81/`. The generated index lists both. Caddy vhost URLs use a **dashed** ops public IP in the hostname (`portal.52-221-251-41.pvc.cloudera-labs.com`, not dotted); that requires wildcard DNS on `caddy_vhost_public_base` or use `caddy_vhost_dns_mode: classic_nipio`. Playbook 28 fails fast if Caddy does not respond on `http://127.0.0.1:<deployment_portal_http_port> (default 81)/` on the ops host.

**Caddy FreeIPA vhost:** When `[ipaserver]` is present, `http://ipa.<ops-ip-dashed>.<base>:81/` **`redir / /ipa/modern-ui/ permanent`** (Labs legacy-only setups use `/ipa/ui`) and reverse-proxies **HTTP** to `<ipaserver-fqdn>` with **`header_up Host`** and fixed **`header_up Referer`** (`/ipa/modern-ui/` or `/ipa/ui` per path — cloudera-labs/openshift pattern). Tier A checks accept **301/308** on `/` and **200/301** on both UI paths; on `ipaserver`, Ansible verifies `/ipa/modern-ui/` and `/ipa/ui` with matching Referer headers. Apache **`mod_substitute`** on ipaserver rewrites embedded IPA FQDN links for browsers without IPA DNS (_ldap._tcp SRV / hosts).

**IPA Apache behind Caddy (ipaserver):** Playbook `configure_ipa_httpd_behind_caddy.yml` (via portal sync) installs `zz-ipa-caddy-proxy.conf` and may comment the HTTPS redirect block in **`ipa-rewrite.conf`** (`ANSIBLE_CADDY_HTTP_UPSTREAM`). After those edits, Ansible reloads the web server **on ipaserver** (delegated), not on the portal ops host. When **`/usr/sbin/ipactl`** exists and **`/etc/ipa/default.conf`** is present, it runs **`apachectl configtest`** (or **`apache2ctl configtest`**) then **`systemctl reload httpd`** (or **`apache2`**). FreeIPA’s **`ipactl`** only supports **`start|stop|restart|status`** for the **whole** stack — there is **no** `ipactl restart httpd`. Routine conf.d / rewrite changes should **not** use **`ipactl restart`** (restarts Directory Server, KDC, DNS, PKI, etc.). For a full-stack recovery use **`systemctl restart ipa.service`** (preferred on RHEL) or **`ipactl restart`** (troubleshooting). Do **not** use **`ipa-server-configure`** / **`ipa-restore`** for Caddy proxy snippets. If reload is skipped because no **`httpd`** unit is registered, install **`ipa-server`** on ipaserver and re-run **PORTAL**. Manual check on ipaserver: `apachectl configtest && systemctl reload httpd`.

**Cloudera Manager (not via Caddy):** Use direct **`https://<cldr-mngr-fqdn>:7183`** (or `:7180` before Auto-TLS) from browsers and Jenkins Tier **B**. Caddy on the ops host serves portal, pgAdmin, monitoring, and IPA only. Optional `cm_external_url` sets a custom published CM URL in portal facts; it does not configure Caddy.

**ECS console (not via Caddy):** Published console URL is **`https://console.<ecs_app_domain>`** (`ecs_control_plane_url_effective`). Override with `ecs_control_plane_url` when needed. Internal ECS **`ApplicationDomain`** stays `ecs_app_domain`.

**Bare metal / private network (no public IP):** Set `deployment_environment: baremetal` (or `deployment_portal_access_profile: private`). The portal index shows only private-network URLs — typically `http://<ops-fqdn>:81/` when `deployment_portal_prefer_fqdn_urls: true`, or `http://<management-ip>:81/` otherwise. pgAdmin stays on port `5050` on the same ops host; database is **cldr-mngr** PostgreSQL. Caddy lab hostnames use the ops management IP (often `caddy_vhost_dns_mode: flat` with IPA/AD DNS).

**Operator access hub:** After `10_setup_deployment_portal.yml` or `35_refresh_deployment_portal.yml`, the index includes an **Operator access — credentials & downloads** panel when `deployment_portal_expose_credentials: true` (default). See [Deployment portal default credentials](#deployment-portal-default-credentials) below for downloads auth, `operator-credentials.json`, lab defaults, and overrides.

#### Deployment portal default credentials

Operators use the deployment portal index on the ops host (`http://<ops>:81/` by default). The **index HTML stays unauthenticated** (Ansible Tier A verify). Secrets appear only in the **Operator access** panel and under **`/downloads/`**.

| Surface | Path / UI | Authentication |
|---------|-----------|----------------|
| Portal index | `:81/` | None |
| Operator access panel | Collapsible section on the index | None — lab/trusted networks only |
| SSH PEMs, JSON bundle | `/downloads/ssh/*`, `/downloads/operator-credentials.json` | HTTP basic auth when `deployment_portal_basic_auth_enabled: true` (default) |

**Downloads HTTP basic auth** applies to **`/downloads/*` only** (not the index). Username: `deployment_portal_basic_auth_user` (default `portal`). Password: `deployment_portal_basic_auth_password` (default resolves to **`postgres_password`** — lab value `postgres`). Use the same user/password for browser downloads and `curl -u portal:<password> …`.

**Operator access panel** mirrors Ansible at sync time: Cloudera Manager (`cm_admin_user` / `cm_admin_pass`), PostgreSQL and pgAdmin, FreeIPA or AD join when configured, Grafana/Prometheus paths when monitoring is enabled, optional Ranger/Knox/Hue/ECS/Jenkins rows from the same vars as playbooks. Nothing is stored in git; re-run `35_refresh_deployment_portal.yml` after changes.

**`operator-credentials.json`** — machine-readable copy of the panel (`basic_auth_enabled`, `auth_username`, `downloads_path_prefix`, `sections[]` → `credentials[]` with `label`, `username`, `password`, `url`, `note`). Rendered to `/downloads/operator-credentials.json` from `deployment_portal_operator_credentials.json.j2`. Same HTTP basic auth as PEM downloads when enabled. Example:

```bash
curl -fsS -u "${DEPLOYMENT_PORTAL_BASIC_AUTH_USER:-portal}:${DEPLOYMENT_PORTAL_BASIC_AUTH_PASSWORD}" \
  "http://<ops-host>:81/downloads/operator-credentials.json" | jq .
```

**Lab default passwords (portal view):** In a fresh lab, CM is typically `admin` / `admin`, IPA admin `admin` / `PseTeam@123`, and pgAdmin, Grafana, and portal downloads auth often share **`postgres_password`** (`postgres`). EC2 SSH uses inventory user `ec2-user` with PEMs under `/downloads/ssh/` when `deployment_portal_expose_ssh_keys: true` (default). Full Ansible variable names and literals: [REFERENCE.md — Lab default passwords](REFERENCE.md#lab-default-passwords-override-before-production) — override there or below; do not paste production secrets into tickets.

**Overrides:** Set passwords and portal toggles in `group_vars/all.yml` or Jenkins job parameter **`ANSIBLE_GROUP_VARS_YAML`** (allowed keys in `jenkins/ansible-group-vars-allowed-keys.yaml`, including `postgres_password`, `cm_admin_pass`, `ipaadmin_password`, `deployment_portal_basic_auth_*`, `deployment_portal_expose_credentials`, `deployment_portal_expose_ssh_keys`). Then run **`35_refresh_deployment_portal.yml`**.

**SSH key downloads:** `deployment_portal_expose_ssh_keys` — **`true`** (default) exports controller keys to `/downloads/ssh/`; **`false`** disables; **`auto`** exports only when downloads basic auth is on. Two labeled PEMs when Terraform `sshkey.pem` and a distinct Auto-TLS key both exist on the controller. Keep `deployment_portal_basic_auth_enabled: true` on untrusted networks; Ansible warns when keys are exposed without basic auth.

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
ansible-playbook -i inventory.ini 27_setup_cm_autotls.yml
ansible-playbook -i inventory.ini 29_setup_cm_cms.yml
ansible-playbook -i inventory.ini 30_setup_cm_ldap.yml
ansible-playbook -i inventory.ini 28_setup_cm_krbs.yml
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
| **Agent heartbeat** | CM → **Hosts**: **Last Heartbeat** fresh (~minutes) on all commissioned hosts. If stale: re-run **27** (agent reconcile) or **`25_reconcile_cm_agents.yml`**; confirm SG **7182/7183** agent→manager and `use_tls` after **27**. |
| **ZooKeeper** | Base cluster → **ZooKeeper** → at least one **Server** role on `base-workers` (playbook **31** fails if zero servers). Required before Stop Cluster / Deploy Client Config after KDC. |
| **Portal / URLs** | `jenkins/artifacts/access-urls.txt` and deployment portal index (when enabled). |

Re-run **`CM_TLS_KRB_LDAP`** only after **`CM_INSTALL`** (and **`IDENTITY`** for FreeIPA) if a mid-pipeline fix is needed; for KDC-only issues re-run **`28_setup_cm_krbs.yml`** from `ansible-playbooks/`.

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
| Wrong identity detected | Run `00_detect_identity.yml`; set `identity_provider: freeipa` or `ad` to override |
| **FreeIPA partial install** (`ipactl status` → **IPA is not configured** / rc=4; `default.conf` missing but **`/var/lib/ipa`** has **`sysrestore.index`** / **`sysrestore.state`** or install dies with **`FileNotFoundError` [Errno 2]** on **`sysupgrade.state`**, **`/etc/ipa/custodia/custodia.conf`**, or other config paths; or empty **`/var/lib/ipa`** without **`sysrestore.state`**; or `/etc/dirsrv/slapd-*` remains; interactive `ipa-server-install --uninstall` defaults to **no**) | See **Manual `ipa-server-install` after a failed run** under Scenario A (one-liner **`mkdir -p /etc/ipa/custodia .../sysupgrade`** after **`rm -rf`**). On **ipaserver** as **root**: unattended uninstall, then **`rm -rf /var/lib/ipa /etc/ipa`** and **`/etc/dirsrv/slapd-*`** when **`ipactl`** is still not configured. Automation: **`12b_ipa_deep_recovery.yml`** with **`ipa_server_deep_recovery: true`**, then **`12_setup_freeipa_server.yml`** (preflight + **`ipa-server-install`**). Optional: **`-e ipa_server_uninstall_force=true`**. |
| Stale `default.conf` (`ipactl` rc=4 / "IPA is not configured", install was skipped) | Playbook **12** removes lone stale `/etc/ipa/default.conf` when no partial debris, then runs `ipa-server-install`. Manual: `rm -f /etc/ipa/default.conf` only if `ipactl status` shows not configured and there is no `/etc/ipa/ca.crt` / DS data; then re-run playbook **12**. |
| FreeIPA configured but stopped (`default.conf` present, `ipactl` healthy, services not RUNNING) | Playbook **12** skips `ipa-server-install` and runs `ensure_ipa_kdc_services.yml` (`systemctl start ipa`, then `ipactl start` if needed). Manual: `systemctl start ipa` or `ipactl start` on ipaserver. |
| CM Kerberos/KDC not enabled (`kerberized=false`) | Playbook **28** waits up to `cm_krb_kerberized_wait_retries × cm_krb_kerberized_wait_delay` (default 300s) then fails with `kerberosInfo` details. **FreeIPA:** on ipaserver `ipactl status` (krb5kdc RUNNING); re-run `12_setup_freeipa_server.yml` then `28_setup_cm_krbs.yml`. **AD:** set `ad_kdc_host` (not empty). **CM:** confirm `importAdminCredentials` in `cloudera-scm-server.log`; Kerberos REST must use HTTPS `:7183` when Auto-TLS is on. **Manual UI:** Administration → Settings → Kerberos — set realm, KDC type/host, import Account Manager principal/password, Save, restart CM Server. |
| CM Kerberos UI warns on **rc4-hmac** / weak crypto | Set `krb5_enc_types` to `aes256-cts aes128-cts` (default). Re-run `12` + `28`; regenerate Kerberos credentials in CM. See **Kerberos encryption types (AES)** above. |
| **ZooKeeper has 0 Servers** (Stop Cluster / Deploy Client Config after KDC) | ZK **service** exists but no **Server** roles — common on clusters created before host template `service: ZOOKEEPER` fix or when **31** skipped create. Add **Server** on `base-workers` in CM, or delete base cluster and re-run **31**. See **ZooKeeper placement** under step 7. Kerberos enablement (`28_setup_cm_krbs.yml` / manual KDC) is separate; fix ZK roles first. **Stop Cluster** can remain blocked until ZK has at least one Server role. |
| CM **Hosts** — **Last Heartbeat** stale (~minutes), all **Commissioned** | **Agent → CM Server** path (heartbeat is not Host Monitor). Check `cloudera-scm-agent`, `server_host` FQDN, `use_tls` after **27**, SG **7182/7183** agent→manager. Re-run **`25_reconcile_cm_agents.yml`** or **27** (agent reconcile play). Chrony: **07_prereq_setup_002.yml**. |
| CM **Hosts** — **Tags** empty | Expected until tags are set (automation: **29** with `cm_host_tags_enabled`, or CM UI). |
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
00-09  Prerequisites
11_identity_setup  Identity + DNS (auto FreeIPA or AD)
16-21  CM install + license
22     Auto-TLS
23-25  Kerberos + LDAP
24     CMS (Management Service)
26     Base cluster (HDFS/YARN/ZK)
99     Cleanup (destructive)
```
