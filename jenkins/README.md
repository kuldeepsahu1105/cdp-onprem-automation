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

## Pipeline parameters

| Parameter | Description |
|---|---|
| `PIPELINE_MODE` | `validate` \| `terraform` \| `ansible` \| `full` |
| `DEPLOY_PHASE` | Ansible: `1` prereqs, `2` identity, `3` CM, `4` CDH base, `5` ECS, `all` |
| `DRY_RUN` | Terraform plan only; Ansible `--check --diff` |
| `ENVIRONMENT` | Override tfvars `ENVIRONMENT` (Terraform workspace) |
| `OWNER` | Override tfvars `OWNER` tag |
| `AWS_REGION` | Override tfvars region |
| `TFVARS_FILE` | Path to config (default: auto-detect) |
| `GIT_BRANCH` | Branch to checkout (default `main`) |
| `NOTIFICATION_EMAIL` | Recipient (defaults to `BUILD_USER_EMAIL`) |
| `REFRESH_JENKINSFILE` | Reload parameter UI and abort |

Jenkins UI overrides (`OWNER`, `ENVIRONMENT`, `AWS_REGION`) take precedence over tfvars when non-empty.

## Stages

```
Build → Check Parameters → Checkout → Validate Prerequisites
  → [Terraform]  (mode: terraform | full)
  → [Ansible]    (mode: ansible | full)
  → Build Summary
```

### Validation (`jenkins/scripts/validate-prereqs.sh`)

- Required CLI tools and valid AWS credentials
- Loads tfvars; checks `ENVIRONMENT`, `AWS_REGION`, `OWNER`
- Ansible syntax check on playbooks
- Requires `inventory.ini` when `PIPELINE_MODE=ansible` (ansible-only)

### Terraform (`jenkins/scripts/run-terraform.sh`)

Runs `./clone_and_run_terraform.sh` — init/plan/apply, generate inventory, copy PEM to `ansible-playbooks/`.

### Ansible (`jenkins/scripts/run-ansible.sh`)

Runs `./clone_and_run_pvc_automation.sh` with `DEPLOY_PHASE` — prerequisites, CM, CDH, ECS as selected.

## Artifacts and email

On success or failure the pipeline archives under `jenkins/artifacts/`:

| Artifact | Content |
|---|---|
| `build-summary.txt` | Environment, phase, inventory summary |
| `terraform-*.log` / `ansible-*.log` | Stage console output |
| `validate-*.log` | Validation output |
| `inventory.ini` | Ansible inventory (when generated) |
| `error-summary.txt` | Parsed errors on failure |
| `*.pem` | SSH key (when Terraform creates one) |

Email includes HTML summary, error block on failure, and attaches available logs and inventory.

## Example runs

| Goal | `PIPELINE_MODE` | `DEPLOY_PHASE` | `DRY_RUN` |
|---|---|---|---|
| Config + AWS + syntax check only | `validate` | any | `false` |
| Plan only (no apply) | `terraform` | — | `true` |
| Provision EC2 + inventory | `terraform` | — | `false` |
| CM install on existing infra | `ansible` | `3` | `false` |
| Full CDH + ECS after Terraform | `full` | `all` | `false` |
| Dry-run Ansible prereqs | `ansible` | `1` | `true` |

## Local testing (without Jenkins)

```bash
chmod +x jenkins/scripts/*.sh
export BUILD_NUMBER=local PIPELINE_MODE=validate
./jenkins/scripts/validate-prereqs.sh
```

## Troubleshooting

| Issue | Fix |
|---|---|
| `OWNER not set` | Set in tfvars or Jenkins `OWNER` parameter |
| `inventory.ini required` | Run `terraform` mode first, or commit/provide inventory |
| `AWS credentials invalid` | Configure agent IAM role or AWS CLI credentials |
| Email not sent | Set `NOTIFICATION_EMAIL` or ensure `BUILD_USER_EMAIL` exists; configure SMTP |
| Ansible SSH failures | Place PEM in `ansible-playbooks/` or set `ANSIBLE_PRIVATE_KEY` on agent |

See the [main README](../README.md) for tfvars layout, deploy phases, and CM archive credentials.
