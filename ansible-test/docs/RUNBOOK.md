# Runbook — How to Use

Step-by-step guide for deploying and tearing down Cloudera Private Cloud with these Ansible playbooks.

All commands assume you are in the `ansible-test/` directory:

```bash
cd ansible-test
```

## Prerequisites

1. Install Ansible collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

2. Prepare `inventory.ini` with your hosts (see [REFERENCE.md](REFERENCE.md#inventory-groups)).
3. Configure `group_vars/all.yml` (domain, passwords, AD vars if needed).
4. Place `license.txt` and SSH key (`id_rsa` or `.pem`) in `ansible-test/`.

## Control node and OS support

The wrappers and playbooks support:

| Control node | How to run |
|---|---|
| Mac laptop (remote) | `brew install ansible jq`; run from repo root or `ansible-test/` |
| RHEL / Ubuntu laptop (remote) | Install `ansible`, `jq`; run `./clone_and_run_pvc_automation.sh` or `cd ansible-test && ./pvc_setup.sh` |
| Cluster node (`cldr-mngr`, `ipaserver`) | `CONTROL_MODE=local DEPLOY_PHASE=all ./pvc_setup.sh` from `ansible-test/` (uses `~/.ssh/id_rsa` if no PEM in cwd) |

When multiple `*.pem` / `id_rsa` or `*license*` files exist in `ansible-test/`, the wrapper prompts you to choose. Override with `ANSIBLE_PRIVATE_KEY`, `LICENSE_FILE`, or `CM_INFO_FILE`.

| Target OS | CM repo mode | Notes |
|---|---|---|
| RHEL 8/9 | `public` or `internal` | Internal mirror: RPM + `createrepo` + CDH parcel |
| Ubuntu 22.04 / 24.04 | `public` or `internal` | Internal mirror: apt `.deb` mirror + CDH parcel; public uses official `cloudera-manager.list` |
| Debian | `public` or `internal`* | *Set `cm_debian_use_ubuntu_repo: true` for apt paths |

**CDH base cluster:** Parcel suffix defaults to `auto` — `jammy`/`noble` on Ubuntu workers, `el8`/`el9` on RHEL. Override with `cdh_parcel_os_suffix: noble` etc.

### Phased deployment (`pvc_setup.sh`)

```bash
DEPLOY_PHASE=1 ./pvc_setup.sh    # prerequisites (00–09)
DEPLOY_PHASE=2 ./pvc_setup.sh    # identity: FreeIPA or AD (auto-detect)
DEPLOY_PHASE=3 ./pvc_setup.sh    # CM install (17/18/19/20/21)
DEPLOY_PHASE=4 ./pvc_setup.sh    # autotls, kerberos, CMS, base cluster
DEPLOY_PHASE=all ./pvc_setup.sh  # full flow
```

Identity is auto-detected: `[ipaserver]` in inventory → FreeIPA; empty ipaserver + `ad_kdc_host` → AD.

---

## Scenario A — AWS deployment with FreeIPA

### 1. Provision infrastructure

From the repo root:

```bash
./clone_and_run_terraform.sh
```

This creates EC2 instances and generates `ansible_inventory.ini`. Copy or symlink it to `ansible-test/inventory.ini`.

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
ansible-playbook -i inventory.ini 10_identity_setup.yml
```

### 6. Run Phase 3 (Cloudera Manager)

```bash
# Public repos (default) — archive.cloudera.com/p/
ansible-playbook -i inventory.ini 17_download_repos.yml \
  -e cm_repo_username="<user>" -e cm_repo_password="<pass>"

# OR internal mirror on cldr-mngr (RHEL: RPM; Ubuntu: apt):
# Set cm_repo_source: internal in group_vars/all.yml, then:
ansible-playbook -i inventory.ini 16_setup_cm_repos.yml \
  -e cm_repo_username="<user>" -e cm_repo_password="<pass>"

ansible-playbook -i inventory.ini 18_setup_postgres.yml
ansible-playbook -i inventory.ini 19_start_cm.yml
ansible-playbook -i inventory.ini 20_verify_cm.yml
ansible-playbook -i inventory.ini 21_setup_cm_license.yml
ansible-playbook -i inventory.ini 22_setup_cm_autotls.yml
ansible-playbook -i inventory.ini 23_setup_cm_krbs.yml
ansible-playbook -i inventory.ini 25_setup_cm_ldap.yml
```

### 7. Run Phase 4 (CMS + base cluster)

```bash
ansible-playbook -i inventory.ini 24_setup_cm_cms.yml
ansible-playbook -i inventory.ini 26_setup_base_cluster.yml
```

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
ansible-playbook -i inventory.ini 10_identity_setup.yml
```

### 5. Cloudera Manager + AD integration

```bash
ansible-playbook -i inventory.ini 19_start_cm.yml
ansible-playbook -i inventory.ini 21_setup_cm_license.yml
ansible-playbook -i inventory.ini 23_setup_cm_krbs.yml
ansible-playbook -i inventory.ini 25_setup_cm_ldap.yml
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
| PostgreSQL listens on 127.0.0.1 only | Re-run `18_setup_postgres.yml` (uses `pg_ctlcluster restart` on Ubuntu) or `pg_ctlcluster 18 main restart` |
| SSH restart fails on Ubuntu | Fixed in `00_setup_ssh_preqs.yml` — uses `ssh` service instead of `sshd` |
| AWS vs bare metal DNS wrong | Set `deployment_environment: aws` or `baremetal` explicitly |
| NetworkManager restart failed | Fixed in `03_create_etc_hosts.yml` — pull latest `main` |

---

## Quick reference — playbook order

```
00-09  Prerequisites
10_identity_setup  Identity + DNS (auto FreeIPA or AD)
16-21  CM install + license
22     Auto-TLS
23-25  Kerberos + LDAP
24     CMS (Management Service)
26     Base cluster (HDFS/YARN/ZK)
99     Cleanup (destructive)
```
