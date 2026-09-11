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
| `LICENSE_FILE` | Cloudera license file path (workspace-relative or absolute on agent). Staged to `ansible-playbooks/license.txt` before Ansible |
| `CM_INFO_FILE` | CM archive `*info.txt` path (`login:` / `password:` lines). Staged into `ansible-playbooks/` |
| `CM_REPO_USERNAME` | Archive.cloudera.com username (alternative to `CM_INFO_FILE`) |
| `CM_REPO_CREDENTIALS_ID` | Jenkins **Username with password** credential ID for archive password (preferred) |
| `CM_REPO_PASSWORD` | Archive password fallback when credential ID is empty (masked in UI; prefer credential ID) |

## License and CM archive credentials (Jenkins → Ansible)

Ansible phases **3+** (`CM_INSTALL`, `CDH_BASE`, `ECS_INSTALL`) require:

1. **Cloudera license file** — set `LICENSE_FILE` or place `*license*` in `ansible-playbooks/`
2. **CM archive credentials** — use **one** of:
   - `CM_INFO_FILE` pointing to an `*info.txt` file in the workspace
   - `CM_REPO_USERNAME` + `CM_REPO_CREDENTIALS_ID` (Jenkins credential)
   - `CM_REPO_USERNAME` + `CM_REPO_PASSWORD` (param fallback)
   - Pre-placed `*info.txt` in `ansible-playbooks/` or values in `group_vars/all.yml`

Before each Ansible phase, `jenkins/scripts/stage-ansible-secrets.sh` copies `LICENSE_FILE` / `CM_INFO_FILE` into `ansible-playbooks/` (mode `600`) and exports env vars consumed by `scripts/lib/ansible_env.sh` (`resolve_license_file`, `load_cm_repo_credentials`).

### Jenkins UI example (CM install)

1. Upload or copy files onto the agent (or use a prior build artifact), e.g.:
   - `/home/holautosa/secrets/cloudera-license.txt`
   - `/home/holautosa/secrets/cm-archive-info.txt`
2. **Build with Parameters:**
   - `PIPELINE_STAGES`: `VALIDATE`, `TERRAFORM`, `CM_INSTALL` (include `PREREQS` on first run)
   - `LICENSE_FILE`: `/home/holautosa/secrets/cloudera-license.txt` (or workspace-relative path)
   - **Option A — info file:** `CM_INFO_FILE`: `/home/holautosa/secrets/cm-archive-info.txt`
   - **Option B — Jenkins credential:** create a **Username with password** credential (e.g. `cloudera-archive`), set `CM_REPO_CREDENTIALS_ID=cloudera-archive` and `CM_REPO_USERNAME` if not stored in the credential
3. Run the job — phase 3 receives staged license + archive login via Ansible extra vars.

`info.txt` format:

```
login: your-cloudera-account
password: your-archive-password
```

Phases 1–2 (`PREREQS`, `IDENTITY`) do not need license or CM archive creds; a warning in logs is expected and harmless.

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

### Security group ingress rules (port 0 / wrong ports)

**Symptoms:** AWS console shows inbound rules with **port 0**, protocol **TCP**, from `0.0.0.0/0` (or your CIDRs) — instead of SSH (22), HTTPS (443), CM ports (7180, etc.).

**Cause:** Older defaults used `allow_all=true` and `allowed_ports=[0]`. When `ALLOW_ALL=false`, a malformed `ALLOWED_PORTS` value (e.g. JSON with spaces like `[22, 443, 80]`) could break Terraform `-var` parsing and fall back to port `0`, creating useless TCP rules.

**Jenkins settings (`SG_MODE=CREATE_NEW`):**

| Parameter | Recommended | Notes |
|---|---|---|
| `ALLOW_ALL` | **unchecked** (`false`) | When checked, one rule allows all protocols (`-1`), not TCP port 0 |
| `ALLOWED_PORTS` | `[22,443,80,7180,7183,7182]` | Compact JSON array — **no spaces** after commas |
| `ALLOWED_CIDRS` | Your office/Jenkins IPs as `/32` | Include Jenkins agent egress IP for Ansible SSH |

**Examples:**

```
ALLOWED_PORTS=[22,443,80,7180,7183,7182]     # correct
ALLOWED_PORTS=[22, 443, 80, 7180, 7183, 7182] # avoid — spaces can break -var parsing
```

`.tfvars.yaml` uses the same compact format:

```yaml
allow_all: false
allowed_ports: '[22,443,80,7180,7183,7182]'
```

**Fix existing SG:** Re-run the Jenkins **TERRAFORM** stage on latest `main` with `SG_MODE=CREATE_NEW` and the settings above. Terraform updates ingress rules in place when the SG is already in state (see [Re-run same environment](#re-run-same-environment-ptgty-etc)). Console should show `[tfvars] Security group: allow_all=false allowed_ports=[22,443,...]` in the log.

**Verify in AWS:** Inbound rules should list individual TCP ports (22, 443, 80, 7180, …), not a single TCP rule on port 0.

### Terraform state on Jenkins (holautosa — PSEAutomation pattern)

Jenkins uses **`CleanBeforeCheckout`** — the workspace is wiped each build. State is **not** stored in S3.

Following [PSEAutomation DeployHoL](https://github.com/cloudera/PSEAutomation/blob/main/OnCloud/AWS/build/Jenkinsfile.DeployHoL), persistent files live under holautosa:

```
/home/holautosa/HOL_AUTO_EXEC_DIR/cdp-onprem-automation/<ENVIRONMENT>/
  terraform/   # terraform.tfstate, terraform.tfstate.d/, *.pem
  ansible/     # inventory.ini, sshkey.pem
```

Each build restores state from holautosa before Terraform/Ansible and persists it back after apply. No S3 backend bucket is created or required.

`.terraform/` (provider/module cache) is **not** persisted — `terraform init` recreates it each build. Jenkins logs should show `State restore v2 (state files only; no .terraform cache)`.

**One-time agent cleanup** (if an older build left a bad module cache):

```bash
sudo rm -rf /home/holautosa/HOL_AUTO_EXEC_DIR/cdp-onprem-automation/ptgty/terraform/.terraform
sudo rm -rf /var/lib/jenkins/workspace/cdp-onprem-automation-deploy/terraform-code/cloudera-pvc-terraform/.terraform
```

**Required sudoers** (same as AWS creds):

```
jenkins ALL=(holautosa) NOPASSWD: ALL
```

The pipeline creates dirs as `holautosa`, then `chown`s `cdp-onprem-automation/` to `jenkins` (PSEAutomation pattern) so later builds can read/write state without sudo.

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

### Ansible SSH connectivity (unreachable hosts)

**Symptoms:** Ansible stage fails with SSH timeouts, `UNREACHABLE`, or `[ansible-preflight] FAIL` in the console.

**Common causes:**

| Cause | Fix |
|---|---|
| Stale `inventory.ini` with **private** IPs (`10.x.x.x`) | Inventory is regenerated from Terraform outputs before each Ansible stage (`regenerate-inventory-from-terraform.sh`). Holautosa restore no longer overwrites `inventory.ini` — only SSH keys. |
| Jenkins agent IP not in security group | Preflight logs `Jenkins/agent egress IP: …` — add that `/32` to **ALLOWED_CIDRS** when `SG_MODE=CREATE_NEW`, or update the existing SG for `USE_EXISTING`. Port **22** must be open. |
| Wrong SSH key or permissions | Terraform PEM is copied to `ansible-playbooks/sshkey.pem` (mode `600`). Ansible user is `root` (`group_vars/all.yml`). |
| Ansible-only run without Terraform | Run `VALIDATE` + `TERRAFORM` once, or ensure holautosa has current state and regenerate inventory manually: `./jenkins/scripts/regenerate-inventory-from-terraform.sh` |

**Preflight:** `jenkins/scripts/ansible-connectivity-preflight.sh` SSH-tests up to five hosts before playbooks run.

**CM credentials warning (phase 1–2):** `No CM archive credentials from env or *info.txt` is expected for `PREREQS` / `IDENTITY` — CM archive login is only required from phase 3 (`CM_INSTALL`) onward.

### Missing license or CM credentials (phase 3+)

| Symptom | Fix |
|---|---|
| `No license file found` | Set **LICENSE_FILE** to a valid path, or place `*license*` in `ansible-playbooks/` before the build |
| CM repo download fails / `Require Cloudera archive credentials` | Set **CM_INFO_FILE**, or **CM_REPO_USERNAME** + **CM_REPO_CREDENTIALS_ID**, or edit `group_vars/all.yml` |
| `LICENSE_FILE not found` in `[stage-secrets]` | Path must exist on the agent; use absolute path or workspace-relative path without `..` |

## Local testing

```bash
export BUILD_NUMBER=local PIPELINE_STAGES=VALIDATE VALIDATION_CHECKS=TOOLS,TFVARS
./jenkins/scripts/validate-prereqs.sh
```

See [main README](../README.md) for tfvars layout and Ansible phases.
