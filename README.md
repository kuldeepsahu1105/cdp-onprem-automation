# CDP On-Prem Automation — Cloudera Data Platform

End-to-end automation for provisioning infrastructure and deploying **Cloudera Private Cloud** (Base + ECS) with **Terraform** and **Ansible**.

Supports **RHEL/Rocky/Alma**, **Ubuntu 22.04/24.04**, and **Debian**, with **FreeIPA** or **Active Directory** for identity, and **public or internal** Cloudera archive repositories (RPM mirror on RHEL, apt mirror on Ubuntu).

## Quick start (AWS)

```bash
mkdir -p cdp_deployment_dir && cd cdp_deployment_dir

wget https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/refs/heads/main/clone_and_run_terraform.sh
wget https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/refs/heads/main/clone_and_run_pvc_automation.sh
wget https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/refs/heads/main/.tfvars.env
# Or use YAML instead of .tfvars.env:
# wget https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/refs/heads/main/.tfvars.yaml

chmod +x clone_and_run_*.sh
# Edit .tfvars.env or .tfvars.yaml, add license + archive credentials, then:
./clone_and_run_terraform.sh      # provision EC2 + inventory
./clone_and_run_pvc_automation.sh # run Ansible deployment
```

Wrapper scripts clone this repo and handle dependencies automatically. See [READme.adoc](READme.adoc) for the full AWS/Terraform workflow, instance sizing, and configuration options.

## Configuration files

Use **either** `.tfvars.env` (shell) **or** `.tfvars.yaml` (structured YAML) in your working directory:

| File | Format | Notes |
|---|---|---|
| `.tfvars.env` | Shell variables | Traditional format; sources shared lib from cloned repo |
| `.tfvars.yaml` | YAML | Easier to read/edit; requires `python3` (PyYAML auto-installed if missing) |

Resolution order: `TFVARS_FILE` (if set) → `.tfvars.yaml` → `.tfvars.yml` → `.tfvars.env`

```bash
# Optional: point to a custom config path
export TFVARS_FILE=/path/to/my-config.yaml
./clone_and_run_terraform.sh
```

Both formats set the same variables and produce the same `TF_VARS` for Terraform. Sections are aligned between `.tfvars.env` and `.tfvars.yaml`:

| Section | Variables |
|---|---|
| General | `AWS_REGION`, `OWNER`, `ENVIRONMENT`, `TERRAFORM_VERSION` |
| Cloudera | `CM_VERSION` |
| AWS resources | `EXISTING_SG_NAME`, `EXISTING_KEYPAIR_NAME` |
| AMI | `AMI_ID` (shared across instance groups) |
| Instance groups | `CLDR_MNGR_*`, `IPA_SERVER_*`, `PVCBASE_*`, `PVCECS_*` |

```bash
# .tfvars.env — edit by section, one variable per line with inline comments
ENVIRONMENT="staging"
PVCBASE_WORKER_COUNT=5
PVCBASE_WORKER_INSTANCE_TYPE="m5.4xlarge"
```

## Documentation

| Document | Audience | Contents |
|---|---|---|
| [READme.adoc](READme.adoc) | **AWS users** | Terraform wrappers, `.tfvars.env`, instance groups, one-click deployment |
| [ansible-test/README.md](ansible-test/README.md) | **Ansible users** | Quick start, defaults, phase summary |
| [ansible-test/docs/RUNBOOK.md](ansible-test/docs/RUNBOOK.md) | **Operators** | Step-by-step deployment, identity scenarios (FreeIPA/AD), cleanup, wrapper scripts |
| [ansible-test/docs/REFERENCE.md](ansible-test/docs/REFERENCE.md) | **Detailed reference** | All playbooks, variables, inventory groups, DNS, repo modes, cleanup toggles |

**Start here:** use the runbook for execution steps; use the reference for variable definitions and playbook details.

## Default versions

Configured in `ansible-test/group_vars/all.yml`:

| Component | Version |
|---|---|
| Cloudera Manager | `7.13.2.10000` |
| CDH (Runtime parcel) | `7.3.2.10000` (`cdh_parcel_os_suffix`: `el8` default) |
| Java | `17` |
| Python | `3.11` |
| PostgreSQL | `18` |

Spark is bundled in the CDH parcel for 7.3.1+ — a separate SPARK3 download is not required.

### Ubuntu notes

- **CM server** on Ubuntu 22.04/24.04: supported with `cm_repo_source: public` or `internal` (apt mirror on cldr-mngr).
- **CDH workers on Ubuntu 22.04/24.04**: parcels `...-jammy.parcel` and `...-noble.parcel` exist in archive; `cdh_parcel_os_suffix: auto` selects them from worker facts.
- **CDH workers on RHEL**: use `el8` / `el9` (or `auto`). ARM64 workers use `el8.aarch64le` / `el9.aarch64le`.
- **Internal mirror**: Ubuntu cldr-mngr mirrors apt `.deb` packages and CDH parcels to its local web server (`16` + `17` playbooks).

## Nutanix Terraform

Provision VMs on Nutanix AHV (separate from the AWS workflow):

```bash
cd nutanix_terraform
cp terraform.tfvars.example terraform.tfvars   # edit cluster, subnet, credentials
terraform init
terraform plan
terraform apply
```

See [nutanix_terraform/README.md](nutanix_terraform/README.md).

## Repository layout

```
cdp-onprem-automation/
├── clone_and_run_terraform.sh    # AWS infra wrapper
├── clone_and_run_pvc_automation.sh
├── .tfvars.env                   # Shell-format deployment config
├── .tfvars.yaml                  # YAML-format deployment config (alternative)
├── READme.adoc                   # AWS deployment guide
├── ansible-test/                 # Ansible playbooks
│   ├── README.md                 # Ansible quick start
│   ├── docs/
│   │   ├── RUNBOOK.md            # How to run (step-by-step)
│   │   └── REFERENCE.md          # Variables, playbooks, inventory
│   ├── group_vars/all.yml        # All configuration defaults
│   └── inventory.ini             # Host groups
├── terraform-code/                 # AWS EC2 Terraform
└── nutanix_terraform/              # Nutanix VM Terraform
```

## Ansible phases (summary)

| Phase | Playbooks | Description |
|---|---|---|
| Prerequisites | `00`–`09` | SSH, hostname, packages, OS tuning |
| Identity & DNS | `00_detect`, `10`–`15` | FreeIPA or AD (auto-detected), DNS |
| Cloudera Manager | `16`–`25` | Repos, PostgreSQL, CM install, Auto-TLS, Kerberos, LDAP |
| CMS & cluster | `24`, `26` | Management Service, base CDH cluster |
| Cleanup | `99` | Toggle-driven teardown |

```bash
cd ansible-test
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory.ini 00_detect_identity.yml
ansible-playbook -i inventory.ini 10_identity_setup.yml
# ... see RUNBOOK.md for full sequence
```

## Key features

- **Identity auto-detection** — FreeIPA when `[ipaserver]` is in inventory; AD when only `ad_kdc_host` is set
- **CM repo modes** — `cm_repo_source: public` (archive.cloudera.com/p/) or `internal` (local mirror on cldr-mngr)
- **OS-independent playbooks** — RHEL and Ubuntu via `os_vars` map
- **Persistent DNS** — netplan (Ubuntu) or resolv.conf; AWS vs bare-metal auto-detection
- **Safe cleanup** — `99_cleanup.yml` with explicit confirmation and per-component toggles

## Authors

- Kuldeep Sahu — ksahu@cloudera.com
- Yash Gulati — ygulati@cloudera.com
