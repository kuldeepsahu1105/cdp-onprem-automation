# Ansible Playbooks — Cloudera Private Cloud

Automation for deploying and cleaning up Cloudera Private Cloud on **RHEL** and **Ubuntu**.

## Quick start

```bash
cd ansible-playbooks
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory.ini 00_detect_identity.yml
DEPLOY_PHASE=all ./pvc_setup.sh
```

For the full deployment sequence, identity scenarios, and cleanup steps, see the runbook below.

## Documentation

| Document | Purpose |
|---|---|
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | **How to run** — step-by-step deployment, FreeIPA/AD scenarios, cleanup, wrapper scripts |
| [docs/REFERENCE.md](docs/REFERENCE.md) | **Detailed reference** — every playbook, variable, inventory group, DNS behavior, repo modes, cleanup toggles |

## OS and repository support

| Component | RHEL 8/9 | Ubuntu 22.04/24.04 |
|---|---|---|
| Prerequisites (`00`–`09`) | Yes | Yes |
| CM install (`19_start_cm`) | Yes | Yes |
| Public CM repo | Yes | Yes |
| Internal CM mirror | RPM + createrepo | apt `.deb` mirror |
| CDH parcels / base cluster | `el8` / `el9` | `jammy` / `noble` |

## Defaults (`group_vars/all.yml`)

| Variable | Default | Notes |
|---|---|---|
| `cm_version` | `7.13.2.10000` | Cloudera Manager |
| `cdh_version` | `7.3.2.10000` | CDH Runtime parcel |
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
| 2 — Identity & DNS | `00_detect`, `10_identity_setup` | `DEPLOY_PHASE=2 ./pvc_setup.sh` |
| 3 — Cloudera Manager | `16`–`21` | `DEPLOY_PHASE=3 ./pvc_setup.sh` |
| 4 — CMS & base cluster | `22`–`26` | `DEPLOY_PHASE=4 ./pvc_setup.sh` |
| 5 — ECS (Data Services) | `27` | `DEPLOY_PHASE=5 ./pvc_setup.sh` |
| Cleanup | `99` | `99_cleanup.yml` |

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for full execution steps and [docs/REFERENCE.md](docs/REFERENCE.md) for playbook and variable details.
