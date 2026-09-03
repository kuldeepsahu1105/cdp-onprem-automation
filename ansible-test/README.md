# Ansible Playbooks — Cloudera Private Cloud

Automation for deploying and cleaning up Cloudera Private Cloud on **RHEL** and **Ubuntu**.

## Quick start

```bash
cd ansible-test
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory.ini 00_detect_identity.yml
ansible-playbook -i inventory.ini 10_identity_setup.yml
```

For the full deployment sequence, identity scenarios, and cleanup steps, see the runbook below.

## Documentation

| Document | Purpose |
|---|---|
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | **How to run** — step-by-step deployment, FreeIPA/AD scenarios, cleanup, wrapper scripts |
| [docs/REFERENCE.md](docs/REFERENCE.md) | **Detailed reference** — every playbook, variable, inventory group, DNS behavior, repo modes, cleanup toggles |

The runbook is the operator guide; the reference is the complete configuration and playbook catalog.

## Defaults (`group_vars/all.yml`)

| Variable | Default | Notes |
|---|---|---|
| `cm_version` | `7.13.2.10000` | Cloudera Manager |
| `cdh_version` | `7.3.2.10000` | CDH Runtime parcel |
| `java_version` | `17` | OpenJDK |
| `python_version` | `3.11` | System Python |
| `postgresql_version` | `18` | External DB for CM |
| `identity_provider` | `auto` | FreeIPA if `[ipaserver]` in inventory; AD if `ad_kdc_host` set |
| `cm_repo_source` | `public` | `public` = archive.cloudera.com/p/; `internal` = local mirror on cldr-mngr |
| `deployment_environment` | `auto` | AWS vs bare-metal DNS behavior |

Spark is bundled in the CDH parcel for `>= 7.3.1` — separate SPARK3 download is skipped automatically. See [REFERENCE.md — Spark parcel](docs/REFERENCE.md#cmcdh-repository-source).

## Phases (summary)

| Phase | Playbooks | Entry point |
|---|---|---|
| 1 — Prerequisites | `00`–`09` | `pvc_setup.sh` or individual playbooks |
| 2 — Identity & DNS | `00_detect`, `10_identity_setup` | `10_identity_setup.yml` |
| 3 — Cloudera Manager | `16`–`25` | Per playbook (see RUNBOOK) |
| 4 — CMS & base cluster | `24`, `26` | Separate steps |
| Cleanup | `99` | `99_cleanup.yml` |

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for full execution steps and [docs/REFERENCE.md](docs/REFERENCE.md) for playbook and variable details.
