# Jenkins Pipeline — CDP On-Prem Automation

Declarative pipeline for validating configuration, optionally provisioning AWS infrastructure with Terraform, and deploying Cloudera PVC (prerequisites → CM → CDH → ECS) with Ansible.

Modeled after [PSEAutomation Jenkinsfile.DeployHoL](https://github.com/cloudera/PSEAutomation/blob/main/OnCloud/AWS/build/Jenkinsfile.DeployHoL): UI parameters, mandatory validation, conditional stages, HTML email on success/failure with logs and artifacts.

## Prerequisites (Jenkins controller / agent)

| Requirement | Notes |
|---|---|
| Jenkins 2.x+ | Pipeline plugin |
| [Email Extension Plugin](https://plugins.jenkins.io/email-ext/) | `emailext` in post actions |
| [AnsiColor Plugin](https://plugins.jenkins.io/ansi-color/) | Optional colored console |
| Agent tools | `git`, `jq`, `aws`, `terraform`, `ansible-playbook`, `python3` (+ PyYAML for `.tfvars.yaml`) |
| AWS credentials | Instance profile on agent, or `aws configure` / `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
| SSH key | For Ansible: `.pem` in `ansible-playbooks/` (from Terraform) or `~/.ssh/id_rsa` on agent |
| Config | `.tfvars.yaml` or `.tfvars.env` in workspace (or set `TFVARS_FILE` parameter) |

## Job setup

1. Create a **Pipeline** job (or Multibranch) pointing at this repo.
2. Set **Pipeline script from SCM** → repository URL → branch `main` → script path `Jenkinsfile`.
3. Run once with **REFRESH_JENKINSFILE** checked to load parameters, or use "Build with Parameters" after first run.
4. Configure Jenkins **Extended E-mail Notification** (SMTP) so `emailext` can send mail.
5. Ensure the agent can reach AWS APIs and (for Ansible) SSH to provisioned hosts.

### Optional credentials

| Credential | Use |
|---|---|
| AWS (IAM user or role) | `aws sts get-caller-identity` must succeed on agent |
| SSH private key | Store as Jenkins secret file; copy to `ansible-playbooks/` before Ansible stage if not using Terraform-generated PEM |
| CM archive / license | `*info.txt`, env vars, or `ansible-playbooks/group_vars/all.yml` (see main README) |

## Pipeline actions (`PIPELINE_ACTION`)

| Action | Terraform | Ansible phase | Inventory required |
|---|---|---|---|
| `validate` | — | — | No |
| `terraform-only` | EC2 + inventory | — | No |
| `prereqs-only` | — | 1 (prerequisites) | Yes |
| `identity-only` | — | 2 (FreeIPA/AD) | Yes |
| `cm-install` | — | 3 (Cloudera Manager) | Yes |
| `cdh-base` | — | 4 (CDH base cluster) | Yes |
| `ecs-install` | — | 5 (ECS Data Services) | Yes |
| `ansible-all` | — | all phases | Yes |
| `full` | EC2 + inventory | all phases | No (created by Terraform) |

Set `DRY_RUN=true` for Terraform plan-only or Ansible check mode.

## Terraform UI overrides (optional)

Leave blank to use values from `.tfvars.yaml` / `.tfvars.env`. Non-empty Jenkins parameters override tfvars via `scripts/lib/jenkins_overrides.sh`.

| Parameter | Maps to tfvars |
|---|---|
| `ENVIRONMENT` | Name prefix + Terraform workspace |
| `OWNER` | EC2 owner tag |
| `AWS_REGION` | AWS region |
| `AMI_ID` | Shared AMI for all instance groups |
| `CLDR_MNGR_COUNT` / `_INSTANCE_TYPE` / `_VOLUME_SIZE` | CM host sizing |
| `IPA_SERVER_COUNT` / `_INSTANCE_TYPE` | FreeIPA sizing |
| `PVCBASE_MASTER_COUNT` | CDH base master count |
| `PVCBASE_WORKER_COUNT` / `_INSTANCE_TYPE` | CDH base workers |
| `PVCECS_MASTER_COUNT` | ECS master count |
| `PVCECS_WORKER_COUNT` / `_INSTANCE_TYPE` | ECS workers |

**Example — smaller dev stack via UI:**

| Parameter | Value |
|---|---|
| `PIPELINE_ACTION` | `terraform-only` |
| `ENVIRONMENT` | `dev-jenkins` |
| `PVCBASE_WORKER_COUNT` | `1` |
| `PVCECS_WORKER_COUNT` | `2` |
| `PVCBASE_WORKER_INSTANCE_TYPE` | `m5.2xlarge` |

## Other parameters

| Parameter | Description |
|---|---|
| `TFVARS_FILE` | Path to config (default: auto-detect) |
| `GIT_BRANCH` | Branch to checkout (default `main`) |
| `NOTIFICATION_EMAIL` | Recipient (defaults to `BUILD_USER_EMAIL`) |
| `REFRESH_JENKINSFILE` | Reload parameter UI and abort |

## Stages

```
Build → Resolve Action → Check Parameters → Checkout → Validate Prerequisites
  → [Terraform — Provision EC2]  (terraform-only | full)
  → [Ansible Deploy]             (prereqs | cm-install | … | full)
  → Build Summary
```

### Validation (`jenkins/scripts/validate-prereqs.sh`)

- Required CLI tools and valid AWS credentials
- Loads tfvars + Jenkins overrides; checks `ENVIRONMENT`, `AWS_REGION`, `OWNER`
- Ansible syntax check (skipped for `terraform-only`)
- Requires `inventory.ini` for Ansible-only actions

### Terraform (`jenkins/scripts/run-terraform.sh`)

Runs `./clone_and_run_terraform.sh` — init/plan/apply, generate inventory, copy PEM to `ansible-playbooks/`.

### Ansible (`jenkins/scripts/run-ansible.sh`)

Runs `./clone_and_run_pvc_automation.sh` with the phase resolved from `PIPELINE_ACTION`.

## Artifacts and email

On success or failure the pipeline archives under `jenkins/artifacts/`:

| Artifact | Content |
|---|---|
| `build-summary.txt` | Action, phase, instance counts, inventory summary |
| `terraform-*.log` / `ansible-*.log` | Stage console output |
| `validate-*.log` | Validation output |
| `inventory.ini` | Ansible inventory (when generated) |
| `error-summary.txt` | Parsed errors on failure |
| `*.pem` | SSH key (when Terraform creates one) |

## Example runs

| Goal | `PIPELINE_ACTION` | Overrides | `DRY_RUN` |
|---|---|---|---|
| Config + syntax check | `validate` | — | `false` |
| Plan EC2 only | `terraform-only` | counts/sizes | `true` |
| Create machines + inventory | `terraform-only` | `ENVIRONMENT`, counts | `false` |
| Ansible prerequisites | `prereqs-only` | — | `false` |
| CM install only | `cm-install` | — | `false` |
| CDH base cluster | `cdh-base` | — | `false` |
| ECS only | `ecs-install` | — | `false` |
| Full stack | `full` | prefix + sizing | `false` |

## Local testing (without Jenkins)

```bash
chmod +x jenkins/scripts/*.sh
export BUILD_NUMBER=local PIPELINE_ACTION=validate REQUIRE_INVENTORY=false
./jenkins/scripts/validate-prereqs.sh
```

## Troubleshooting

| Issue | Fix |
|---|---|
| `OWNER not set` | Set in tfvars or Jenkins `OWNER` parameter |
| `inventory.ini required` | Run `terraform-only` or `full` first, or provide inventory |
| `AWS credentials invalid` | Configure agent IAM role or AWS CLI credentials |
| Email not sent | Set `NOTIFICATION_EMAIL` or ensure `BUILD_USER_EMAIL` exists; configure SMTP |
| Ansible SSH failures | Place PEM in `ansible-playbooks/` or set `ANSIBLE_PRIVATE_KEY` on agent |

See the [main README](../README.md) for tfvars layout, deploy phases, and CM archive credentials.
