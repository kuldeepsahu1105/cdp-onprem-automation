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
PVCECS_WORKER_COUNT=7
PVCECS_WORKER_VOLUME_SIZE=1300
```

CDH and ECS **software versions** and cluster settings are configured in Ansible (`ansible-test/group_vars/all.yml`), not in `.tfvars.env` / `.tfvars.yaml`. Terraform only provisions the EC2 instance groups; Ansible deploys the clusters onto those hosts.

## CDH base cluster deployment

The CDP **base cluster** (HDFS, YARN, ZooKeeper) is deployed by Ansible playbook `26_setup_base_cluster.yml` after Cloudera Manager, Auto-TLS, Kerberos, and CMS are in place.

### Terraform instance groups (infrastructure)

| Group | `.tfvars.env` variables | Default | Purpose |
|---|---|---|---|
| `pvcbase_master` | `PVCBASE_MASTER_COUNT`, `PVCBASE_MASTER_INSTANCE_TYPE`, `PVCBASE_MASTER_VOLUME_SIZE` | 1 × m5.4xlarge, 400 GB | Base cluster master |
| `pvcbase_worker` | `PVCBASE_WORKER_COUNT`, `PVCBASE_WORKER_INSTANCE_TYPE`, `PVCBASE_WORKER_VOLUME_SIZE` | 3 × m5.4xlarge, 400 GB | Base cluster workers |

### Ansible inventory groups

| Group | Maps from Terraform | Required host vars |
|---|---|---|
| `base-masters` | `pvcbase_master` | `ansible_host`, `private_ip`, `cldr_hostname` |
| `base-workers` | `pvcbase_worker` | same |

Terraform generates `inventory.ini` with these groups when you run `clone_and_run_terraform.sh`.

### Key Ansible variables (`group_vars/all.yml`)

| Variable | Default | Description |
|---|---|---|
| `cdh_version` | `7.3.2.10000` | CDH Runtime parcel version |
| `cdh_numeric_version` | `82216952` | Parcel build number (used to build full parcel name) |
| `cdh_basecluster_name` | `CDH-Cluster` | Cluster name in Cloudera Manager |
| `base_cluster_master_group` | `base-masters` | Inventory group for master host |
| `base_cluster_worker_group` | `base-workers` | Inventory group for worker hosts |
| `cdh_parcel_os_suffix` | `auto` | Parcel OS suffix: `auto`, `el8`, `el9`, `jammy`, `noble`, `el8.aarch64le` |
| `cdh_parcel_target_group` | `base-workers` | Group used to auto-detect worker OS for parcel suffix |
| `cm_repo_source` | `public` | `public` = archive.cloudera.com/p/; `internal` = mirror on cldr-mngr |
| `cm_repo_username` / `cm_repo_password` | — | Required archive credentials |
| `parcel_repo` | computed | CDH parcel download URL (public or internal mirror) |

Spark is bundled in the CDH parcel for `>= 7.3.1` — no separate SPARK3 download is needed.

```bash
# Override at deploy time (example)
ansible-playbook -i inventory.ini 26_setup_base_cluster.yml \
  -e cdh_version=7.3.2.10000 \
  -e cdh_parcel_os_suffix=noble
```

## ECS (Data Services) deployment

**ECS** (Cloudera Data Services / Experience Cluster) runs on dedicated nodes and is deployed by `27_setup_ecs_cluster.yml`. It requires the base CDH cluster (`26`) and wildcard DNS (`*.apps.<domain>`) when using FreeIPA.

### Terraform instance groups (infrastructure)

| Group | `.tfvars.env` variables | Default | Purpose |
|---|---|---|---|
| `pvcecs_master` | `PVCECS_MASTER_COUNT`, `PVCECS_MASTER_INSTANCE_TYPE`, `PVCECS_MASTER_VOLUME_SIZE` | 1 × m5.8xlarge, 1300 GB | ECS control-plane node |
| `pvcecs_worker` | `PVCECS_WORKER_COUNT`, `PVCECS_WORKER_INSTANCE_TYPE`, `PVCECS_WORKER_VOLUME_SIZE` | 7 × r5a.4xlarge, 1300 GB | ECS worker nodes |

ECS nodes need larger root volumes (default 1300 GB) for Docker, Longhorn, and local storage.

### Ansible inventory groups

| Group | Maps from Terraform | Required host vars |
|---|---|---|
| `ecs-masters` | `pvcecs_master` | `ansible_host`, `private_ip`, `cldr_hostname` |
| `ecs-workers` | `pvcecs_worker` | same |

Set `PVCECS_*_COUNT=0` in tfvars to skip ECS infrastructure entirely, or leave groups empty and ECS deployment is skipped automatically.

### Key Ansible variables (`group_vars/all.yml`)

| Variable | Default | Description |
|---|---|---|
| `ecs_deploy_enabled` | `auto` | `auto` = deploy when ecs inventory groups exist; `true` / `false` to force |
| `ecs_cluster_name` | `ECS-Cluster` | ECS cluster name in Cloudera Manager |
| `ecs_cluster_master_group` | `ecs-masters` | Inventory group for ECS master |
| `ecs_cluster_worker_group` | `ecs-workers` | Inventory group for ECS workers |
| `ecs_pvc_ds_version` | `1.5.5-h2000` | CDS repo tag (CDS 1.5.5 SP2; use `1.5.5-h2100` for SP2 CHF1) |
| `ecs_pvc_repository_url` | computed | `https://archive.cloudera.com/p/cdp-pvc-ds/<version>` |
| `ecs_parcel_repo_url` | computed | ECS parcel repo under CDS path |
| `ecs_parcel_version` | `""` | Optional override; auto-discovered from CM when empty |
| `ecs_app_domain` | `apps.<cluster_domain>` | Application domain for ECS services |
| `ecs_docker_data_path` | `/mnt/docker` | Docker data directory |
| `ecs_lso_data_path` | `/ecs/local` | Local storage operator path |
| `ecs_longhorn_data_path` | `/ecs/longhorn-storage` | Longhorn persistent volume path |
| `ecs_longhorn_replication` | `2` | Longhorn replica count |
| `ecs_control_plane_database_mode` | `embedded` | `embedded` or `existing` (external DB needs full config) |
| `ecs_control_plane_vault_mode` | `embedded` | Vault storage mode |
| `ecs_k8s_webui_secret_admin_token` | `ChangeMe@ECS-WebUI` | K8s web UI admin token — change before deploy |

Compatible with CDH 7.3.2: CDS 1.5.5 SP2+ (see Cloudera release matrix).

```bash
# ECS only (after base cluster is up)
cd ansible-test
DEPLOY_PHASE=5 ./pvc_setup.sh

# Or run playbook directly
ansible-playbook -i inventory.ini 27_setup_ecs_cluster.yml \
  -e ecs_pvc_ds_version=1.5.5-h2000
```

### ECS cleanup toggles (`99_cleanup.yml`)

| Variable | Default | Description |
|---|---|---|
| `cleanup_delete_ecs_cluster` | `false` | Delete ECS cluster via CM API + node cleanup |
| `cleanup_reset_iptables` | `false` | Reset iptables on ECS nodes |
| `cleanup_ecs_remove_docker_registry` | `true` | Remove local Docker registry |
| `cleanup_ecs_run_rke2_killall` | `true` | Run rke2-killall on ECS nodes |

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
| CDH (Runtime parcel) | `7.3.2.10000` (`cdh_parcel_os_suffix`: `auto` default) |
| Java | `17` |
| Python | `3.11` |
| PostgreSQL | `18` |

Spark is bundled in the CDH parcel for 7.3.1+ — a separate SPARK3 download is not required.

### Ubuntu notes

- **CM server** on Ubuntu 22.04/24.04: supported with `cm_repo_source: public` or `internal` (apt mirror on cldr-mngr).
- **CDH workers on Ubuntu 22.04/24.04**: parcels `...-jammy.parcel` and `...-noble.parcel` exist in archive; `cdh_parcel_os_suffix: auto` selects them from worker facts. See [CDH base cluster deployment](#cdh-base-cluster-deployment).
- **CDH workers on RHEL**: use `el8` / `el9` (or `auto`). ARM64 workers use `el8.aarch64le` / `el9.aarch64le`.
- **ECS (Data Services)**: see [ECS deployment](#ecs-data-services-deployment) for instance groups, variables, and `27_setup_ecs_cluster.yml`.
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
| Identity & DNS | `00_detect`, `10`–`15` | FreeIPA or AD (auto-detected), DNS, wildcard `*.apps` |
| Cloudera Manager | `16`–`25` | Repos, PostgreSQL, CM install, Auto-TLS, Kerberos, LDAP |
| CMS & base cluster | `24`, `26` | Management Service, CDH base cluster (HDFS/YARN/ZK) |
| ECS (Data Services) | `27` | Experience cluster on `ecs-masters` / `ecs-workers` (skipped when groups empty) |
| Cleanup | `99` | Toggle-driven teardown (base cluster, ECS, CMS, CM) |

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
