# Ansible Playbooks — Cloudera Private Cloud

Automation for deploying and cleaning up Cloudera Private Cloud on **RHEL** and **Ubuntu**.

## Quick start

```bash
cd ansible-playbooks
# Edit config.yml for this deployment; keep secrets in Vault or an extra-vars file.
./run-playbook.sh detect_identity.yml    # or: ansible-playbook … (imports ensure_collections.yml)
DEPLOY_PHASE=all ./pvc_setup.sh             # or repo clone_and_run_pvc_automation.sh
```

For an **Ansible-only deployment without Terraform**, start from the included
inventory template:

```bash
cp inventory.example.ini inventory.ini
vi inventory.ini
vi config.yml
ansible all -i inventory.ini -m ping -e @config.yml
DEPLOY_PHASE=all ./pvc_setup.sh
```

Use `ansible_host` for the controller-reachable address, `private_ip` for
cluster traffic, and optional `public_ip` for public portal links. Deployment
playbooks load `config.yml` automatically. Add `-e @config.yml` to direct
ad-hoc `ansible` commands that need deployment variables.

Supported execution paths:

| Controller | Managed nodes | Mode |
|---|---|---|
| macOS | RHEL or Ubuntu | Remote |
| Ubuntu or RHEL | RHEL or Ubuntu | Remote |
| IPAServer | RHEL or Ubuntu | Local/in-VPC |
| Jenkins agent | RHEL or Ubuntu | Remote or in-VPC |

For the shortest deployment sequence and cleanup path, see the runbook below.

## Documentation

| Document | Purpose |
|---|---|
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | **Quick runbook** — prepare, validate, deploy, verify, and clean up |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | **Configuration guide** — every `config.yml` option, accepted values, effects, and credential inputs |
| [docs/OPERATIONS_GUIDE.md](docs/OPERATIONS_GUIDE.md) | **Detailed operations** — controller/network scenarios, FreeIPA/AD, portal verification, recovery, and troubleshooting |
| [docs/RUN_ORDER.md](docs/RUN_ORDER.md) | **Run order** — Jenkins / `pvc_setup.sh` sequence (unique numbers 10–35) |
| [docs/REFERENCE.md](docs/REFERENCE.md) | **Detailed reference** — every playbook, variable, inventory group, DNS behavior, repo modes, cleanup toggles |

## OS and repository support

| Component | RHEL 8/9 | Ubuntu 22.04/24.04 |
|---|---|---|
| Prerequisites (`00`–`09`) | Yes | Yes |
| CM install (`24_start_cm`) | Yes | Yes |
| Public CM repo | Yes | Yes |
| Internal CM mirror | RPM + createrepo | apt `.deb` mirror |
| CDH parcels / base cluster | `el8` / `el9` | `jammy` / `noble` |

## Configuration

Edit [`config.yml`](config.yml) for deployment-specific values such as domains,
product versions, services, parcel/CSD overrides, ECS, and portal settings.
[`group_vars/all.yml`](group_vars/all.yml) contains stable defaults, derived
values, compatibility aliases, and OS package maps; it normally does not need
editing. Jenkins and command-line extra vars take precedence over both files.

Keep passwords out of Git and provide them through Ansible Vault, Jenkins
credentials, or an extra-vars file:

```bash
ansible-playbook -i inventory.ini 31_setup_base_cluster.yml \
  -e @secrets.yml
```

### Main defaults

| Variable | Default | Notes |
|---|---|---|
| `cm_version` | `7.13.2.6` | Cloudera Manager |
| `cdh_version` | `7.3.2.0` | CDH Runtime parcel |
| `cdh_parcel_os_suffix` | `auto` | `noble`, `jammy`, `el8`, `el9`, or `auto` from worker OS |
| `java_version` | `17` | OpenJDK |
| `python_version` | `3.11` | System Python |
| `postgresql_version` | `18` | External DB for CM |
| `identity_provider` | `auto` | FreeIPA if `[ipaserver]` in inventory; AD if `ad_kdc_host` set |
| `cm_repo_source` | `public` | `public` = archive.cloudera.com/p/; `internal` = local mirror on cldr-mngr |
| `deployment_environment` | `auto` | AWS vs bare-metal DNS behavior |
| `ecs_deploy_enabled` | `auto` | Deploy ECS when `[ecs-masters]` / `[ecs-workers]` exist in inventory |
| `ecs_pvc_ds_version` | `1.5.5-h3300` | CDS repo tag (CDS 1.5.5 SP3 CHF3) |
| `ecs_cluster_name` | `ECS-Cluster` | ECS cluster name in Cloudera Manager |

Spark is bundled in the CDH parcel for `>= 7.3.1` — separate SPARK3 download is skipped automatically. See [REFERENCE.md — Spark parcel](docs/REFERENCE.md#cmcdh-repository-source).

## Phases (summary)

| Phase | Playbooks | Entry point |
|---|---|---|
| 1 — Prerequisites | `00`–`09` | `DEPLOY_PHASE=1 ./pvc_setup.sh` |
| 2 — Identity & DNS | `00_detect`, `11_identity_setup` | `DEPLOY_PHASE=2 ./pvc_setup.sh` |
| 3 — Cloudera Manager | `20`–`26` | `DEPLOY_PHASE=3 ./pvc_setup.sh` |
| 4 — TLS, CMS & base cluster | `27`–`31` | `DEPLOY_PHASE=4 ./pvc_setup.sh` |
| 5 — ECS (Data Services) | `33` (+ optional `34`) | `DEPLOY_PHASE=5 ./pvc_setup.sh` |
| Cleanup | `99` | `99_cleanup.yml` |

**Dry run:** `DRY_RUN=true ./pvc_setup.sh` or `./pvc_setup.sh --dry-run` — runs Ansible with `--check --diff`. Terraform wrapper: `DRY_RUN=true ./clone_and_run_terraform.sh` (plan only).

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for the operator quick path,
[docs/OPERATIONS_GUIDE.md](docs/OPERATIONS_GUIDE.md) for detailed procedures,
and [docs/REFERENCE.md](docs/REFERENCE.md) for playbook and variable details.
