# Jenkins Pipeline — CDP On-Prem Automation

Declarative pipeline with **checkbox stage selection**, **configurable validation checks**, and **REFRESH_JENKINSFILE** support.

## Required Jenkins plugins

| Plugin | Purpose |
|---|---|
| Pipeline | Declarative pipeline |
| [Extended Choice Parameter](https://plugins.jenkins.io/extended-choice-parameter/) | `PIPELINE_STAGES` and `VALIDATION_CHECKS` checkboxes |
| [Email Extension](https://plugins.jenkins.io/email-ext/) | Success/failure notifications |
| [AnsiColor](https://plugins.jenkins.io/ansi-color/) | Colored console (optional) |

## Reload parameters after Jenkinsfile changes

1. Open **Build with Parameters**
2. Set **REFRESH_JENKINSFILE** = `YES`
3. Run the job — it aborts immediately after reloading the parameter UI
4. Run again with your desired stage checkboxes

## Default parameter values

Defaults match `.tfvars.yaml` in the repo (refresh Jenkinsfile after updates):

| Parameter | Default |
|---|---|
| `PIPELINE_STAGES` | `VALIDATE,TERRAFORM` |
| `VALIDATION_CHECKS` | `TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY` |
| `ENVIRONMENT` | `development` |
| `OWNER` | `ksahu-ygulati` |
| `AWS_REGION` | `ap-southeast-1` |
| `AMI_ID` | `ami-0a66a47c24c021954` |
| `TFVARS_FILE` | `.tfvars.yaml` |
| `GIT_BRANCH` | `main` |
| Instance counts/types | Same as `.tfvars.yaml` instance_groups |

If `PIPELINE_STAGES` is empty (old job config), the pipeline falls back to `VALIDATE,TERRAFORM`.

## Stage checkboxes (`PIPELINE_STAGES`)

Select one or more stages (executed in order):

| Checkbox | What runs |
|---|---|
| `VALIDATE` | Tools, AWS, tfvars, Ansible syntax (per `VALIDATION_CHECKS`) |
| `TERRAFORM` | EC2 + `inventory.ini` + PEM |
| `PREREQS` | Ansible phase 1 — prerequisites |
| `IDENTITY` | Ansible phase 2 — FreeIPA/AD |
| `CM_INSTALL` | Ansible phase 3 — Cloudera Manager |
| `CDH_BASE` | Ansible phase 4 — CDH base cluster |
| `ECS_INSTALL` | Ansible phase 5 — ECS Data Services |

**Examples:**

| Goal | Checkboxes |
|---|---|
| Validation only | `VALIDATE` |
| Create machines only | `VALIDATE`, `TERRAFORM` |
| Prerequisites only | `VALIDATE`, `PREREQS` |
| CM install only | `VALIDATE`, `CM_INSTALL` |
| Terraform + CM | `VALIDATE`, `TERRAFORM`, `CM_INSTALL` |
| Full stack | All stages |

Ansible-only stages (no `TERRAFORM`) require existing `ansible-playbooks/inventory.ini`.

Multiple Ansible checkboxes run **sequentially** (e.g. `PREREQS` + `CM_INSTALL` runs phase 1 then phase 3).

## Validation checkboxes (`VALIDATION_CHECKS`)

Used when `VALIDATE` stage is selected:

| Checkbox | Check |
|---|---|
| `TOOLS` | `git`, `jq`, `aws`, `terraform`, `ansible-playbook`, `python3` |
| `AWS_CREDS` | `aws sts get-caller-identity` |
| `TFVARS` | Config file exists; `ENVIRONMENT`, `OWNER`, `AWS_REGION` loaded |
| `ANSIBLE_SYNTAX` | `ansible-playbook --syntax-check` on playbooks |
| `INVENTORY` | `ansible-playbooks/inventory.ini` exists |
| `EMAIL_FORMAT` | `NOTIFICATION_EMAIL` format (when set) |

`INVENTORY` is auto-added when Ansible stages run without `TERRAFORM`.

## Input validation (Groovy — before checkout)

Fails fast with clear errors for:

- Empty `PIPELINE_STAGES` (unless `REFRESH_JENKINSFILE=YES`)
- Invalid `AWS_REGION`, `ENVIRONMENT`, `AMI_ID`, instance types
- Non-integer or zero counts/volume sizes
- Invalid `GIT_BRANCH`, `TFVARS_FILE` path traversal
- Invalid `NOTIFICATION_EMAIL` (when `EMAIL_FORMAT` check selected)

Warnings (non-blocking): ECS without CDH, CM without prereqs.

## Terraform UI overrides

Leave blank to use `.tfvars.yaml` / `.tfvars.env`:

| Parameter | Maps to |
|---|---|
| `ENVIRONMENT` | Name prefix + Terraform workspace |
| `OWNER` | EC2 owner tag |
| `AWS_REGION` | AWS region |
| `AMI_ID` | Shared AMI |
| `CLDR_MNGR_*`, `IPA_SERVER_*`, `PVCBASE_*`, `PVCECS_*` | Instance counts, types, volumes |

## Other parameters

| Parameter | Description |
|---|---|
| `DRY_RUN` | Terraform plan only / Ansible `--check --diff` |
| `TFVARS_FILE` | Relative config path (auto-detect if empty) |
| `GIT_BRANCH` | Branch to checkout |
| `NOTIFICATION_EMAIL` | Email recipient |

## Artifacts

| File | Content |
|---|---|
| `build-summary.txt` | Stages, instance counts, inventory |
| `terraform-*.log` | Terraform output |
| `ansible-*-phaseN.log` | Per-phase Ansible output |
| `validate-*.log` | Validation output |
| `inventory.ini`, `*.pem` | Deployment artifacts |

## Troubleshooting

### `InvalidClientTokenId` even with EC2 IAM role attached

The AWS CLI does **not** use the instance role when any of these are set with invalid/expired keys:

- Jenkins job **AWS Credentials** binding
- Global Jenkins env: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- Jenkins user `~/.aws/credentials` with a bad `[default]` profile

**Fix:** Keep pipeline parameter **AWS_USE_INSTANCE_ROLE** enabled (default). The pipeline loads a short-lived session from the EC2 instance IAM role (IMDS) for that build step only — it does **not** delete or modify `~/.aws/credentials`, Jenkins credential bindings, or any files on the agent.

**Verify on the agent as the `jenkins` user:**

```bash
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
aws sts get-caller-identity
```

If you use Jenkins AWS credential bindings, disable **AWS_USE_INSTANCE_ROLE** or update the binding with valid keys.

## Local testing

```bash
export BUILD_NUMBER=local PIPELINE_STAGES=VALIDATE VALIDATION_CHECKS=TOOLS,TFVARS
./jenkins/scripts/validate-prereqs.sh
```

See [main README](../README.md) for tfvars layout and Ansible phases.
