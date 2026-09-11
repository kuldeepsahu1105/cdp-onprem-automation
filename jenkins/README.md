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
| `AMI_ID` | `ami-030a276b398df7eb7` (ap-southeast-1) |
| `TFVARS_FILE` | `.tfvars.yaml` |
| `GIT_BRANCH` | `main` |
| `CREDENTIALS_USER` | `holautosa` (uses `/home/holautosa/.aws` and `~/.ssh` read-only) |
| `USE_CREDENTIALS_USER_AWS` | `true` (checked — holautosa `~/.aws`; uncheck for EC2 IAM role via IMDS) |
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

### AWS credentials (`holautosa`)

Reads from **`/home/holautosa/.aws/`**. If the `jenkins` user cannot read those files directly, the pipeline stages copies into `jenkins/artifacts/` using `sudo -u holautosa cat` (holautosa files are never modified).

**Required sudoers** (on the Jenkins agent):

```
jenkins ALL=(holautosa) NOPASSWD: ALL
```

Terraform/Ansible run as **`jenkins`** (workspace owner) with staged or direct holautosa AWS credentials.

Uncheck **USE_CREDENTIALS_USER_AWS** only to use the EC2 IAM role instead of holautosa `~/.aws`.

### Credentials user (`holautosa`)

By default the pipeline uses **`CREDENTIALS_USER=holautosa`**:

- AWS: `/home/holautosa/.aws/credentials` and `config`
- SSH: `/home/holautosa/.ssh/id_rsa` or `id_ed25519` for Ansible

Files are read only — nothing is deleted or modified on the agent.

If the Jenkins `jenkins` user cannot read holautosa's files, grant read access or configure passwordless `sudo -u holautosa` for pipeline steps.

Set **AWS_USE_INSTANCE_ROLE=true** only when you want EC2 IAM role (IMDS) instead of holautosa's `~/.aws`.

### `cannot read /home/holautosa/.aws/credentials`

**Cause:** Jenkins checked out an older commit, or the agent lacks read/sudo access to holautosa's `~/.aws`.

**Fix:**

1. Rebuild on latest `main` (includes sudo staging into `jenkins/artifacts/`).
2. On the Jenkins agent, add sudoers (files on holautosa are never modified):

   ```
   jenkins ALL=(holautosa) NOPASSWD: ALL
   ```

3. Or uncheck **USE_CREDENTIALS_USER_AWS** to use the EC2 IAM role instead of holautosa `~/.aws`.

**Verify:**

```bash
sudo -u holautosa aws sts get-caller-identity
sudo -u jenkins sudo -n -u holautosa cat /home/holautosa/.aws/credentials | head -1
```

### VPC and security group (Jenkins UI)

| Parameter | Default | Meaning |
|---|---|---|
| `VPC_MODE` | `USE_DEFAULT` | Use account default VPC (`create_vpc=false`) |
| `VPC_MODE` | `CREATE_NEW` | Create VPC — set `VPC_NAME`, `VPC_CIDR_BLOCK`, `VPC_AZS`, subnets, NAT/VPN |
| `SG_MODE` | `USE_EXISTING` | Lookup SG by name or `sg-id` (default `{ENVIRONMENT}-pvc_cluster_sg`) |
| `SG_MODE` | `CREATE_NEW` | Terraform creates SG — set `SG_NAME`, `ALLOWED_CIDRS`, `ALLOW_ALL`, `ALLOWED_PORTS` |
| `CREATE_EIP` | `true` | Elastic IP for Cloudera Manager |

Naming suffix in `.tfvars.yaml`: `sg_name_suffix: pvc_cluster_sg` → `{ENVIRONMENT}-pvc_cluster_sg`.

If `USE_EXISTING` fails (SG not in VPC), switch to **SG_MODE=CREATE_NEW** or set **EXISTING_SG_NAME** to a valid `sg-xxxxxxxx` ID.

### Terraform state on Jenkins (holautosa — PSEAutomation pattern)

Jenkins uses **`CleanBeforeCheckout`** — the workspace is wiped each build. State is **not** stored in S3.

Following [PSEAutomation DeployHoL](https://github.com/cloudera/PSEAutomation/blob/main/OnCloud/AWS/build/Jenkinsfile.DeployHoL), persistent files live under holautosa:

```
/home/holautosa/HOL_AUTO_EXEC_DIR/cdp-onprem-automation/<ENVIRONMENT>/
  terraform/   # terraform.tfstate, .terraform/, *.pem
  ansible/     # inventory.ini, sshkey.pem
```

Each build restores state from holautosa before Terraform/Ansible and persists it back after apply. No S3 backend bucket is created or required.

Requires passwordless `sudo` for `jenkins` → `holautosa` if the `jenkins` user cannot write `/home/holautosa/HOL_AUTO_EXEC_DIR` directly.

### Re-run same environment (`ptgty`, etc.)

Terraform workspace state is per `ENVIRONMENT` under holautosa. On re-runs:

| Resource | First run | Re-run behavior |
|---|---|---|
| **Key pair** | Created in AWS + `.pem` in workspace | If AWS key exists but not in state → adopt existing key (reuse `.pem` from workspace/artifacts) |
| **Security group** (`SG_MODE=CREATE_NEW`) | Created in AWS | If SG exists but not in state → **import** into Terraform so ingress rules can be updated in place |
| **Security group** (`SG_MODE=USE_EXISTING`) | Data source lookup only | No create/import — rules are **not** managed by Terraform |

SG ingress **can** be updated by Terraform when the SG is in state (`CREATE_NEW` + import or first successful apply). `USE_EXISTING` only attaches the SG to instances; it does not change rules.

Duplicate errors (`InvalidKeyPair.Duplicate`, `InvalidGroup.Duplicate`) are handled automatically by `reconcile_terraform_resources.sh` before `terraform plan`.

### SSH key pair (Jenkins)

Jenkins **always creates a new EC2 key pair** per run using the tfvars naming convention:

```
{ENVIRONMENT}-{keypair_name_suffix}
```

Default suffix: `pvc-new-keypair` (e.g. `ptgty-pvc-new-keypair` when `ENVIRONMENT=ptgty`).

Terraform writes `{KEYPAIR_NAME}.pem` to the terraform directory; the wrapper copies it to `ansible-playbooks/sshkey.pem`. Ansible uses that PEM before holautosa `~/.ssh`.

Override suffix in `.tfvars.yaml`:

```yaml
keypair_name_suffix: pvc-new-keypair
```

### `no matching EC2 Key Pair found`

**Cause:** Older builds used `create_keypair: false` with a missing `existing_keypair_name`.

**Fix:** Rebuild on latest `main` — Jenkins forces `create_keypair: true` automatically.

### `InvalidGroupId.Malformed` / security group name

**Cause:** Older Terraform module only accepted `sg-...` IDs; tfvars often use a **group name** (e.g. `testing-pvc_cluster_sg`).

**Fix:** Latest `main` resolves SG by name or ID. Rebuild on latest `main`, or set `existing_sg_name` to a valid `sg-xxxxxxxx` ID.

### `InvalidClientTokenId`

**Fix:** Ensure `/home/holautosa/.aws/credentials` is valid. Keep **USE_CREDENTIALS_USER_AWS** checked (default) when using holautosa creds.

## Local testing

```bash
export BUILD_NUMBER=local PIPELINE_STAGES=VALIDATE VALIDATION_CHECKS=TOOLS,TFVARS
./jenkins/scripts/validate-prereqs.sh
```

See [main README](../README.md) for tfvars layout and Ansible phases.
