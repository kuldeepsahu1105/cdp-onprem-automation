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

Parameter **help text** (stages, validation checks, security group, `ALLOWED_PORTS`, `CLDR_EIP_NAME`, etc.) lives in the Jenkinsfile `description` / `descriptionPropertyValue` fields and appears on **Build with Parameters** after a refresh. Stage and validation checkboxes also show a **per-option summary** next to each name via Extended Choice `descriptionPropertyValue`.

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

**Legacy token:** Older jobs may still submit `CDH_INSTALL` instead of **`CDH_BASE`**. Current Jenkinsfiles map `CDH_INSTALL` → `CDH_BASE` automatically; reload parameters with **REFRESH_JENKINSFILE=YES** so the checkbox label matches. If every deploy stage is skipped but the build is green, check the log for `Resolved stages: validate=false, terraform=false, ansible=false` — that usually means an unrecognized stage name.

## Stage checkboxes (`PIPELINE_STAGES`)

Select one or more of the **seven** stage checkboxes: `VALIDATE`, `TERRAFORM`, `PREREQS`, `IDENTITY`, `CM_INSTALL`, `CDH_BASE`, `ECS_INSTALL`. The pipeline always runs selected stages in this order (not checkbox order):

`VALIDATE` → `TERRAFORM` → `PREREQS` → `IDENTITY` → `CM_INSTALL` → `CDH_BASE` → `ECS_INSTALL`

| Checkbox | What runs |
|---|---|
| `VALIDATE` | `validate-prereqs.sh` — only checks selected in `VALIDATION_CHECKS` (no deploy) |
| `TERRAFORM` | EC2/VPC/SG/EIP via Terraform; `inventory.ini` + `.pem` key |
| `PREREQS` | Ansible **phase 1** — OS prereqs, Java, Python, firewall, SSH bootstrap |
| `IDENTITY` | Ansible **phase 2** — FreeIPA or Active Directory (from inventory) |
| `CM_INSTALL` | Ansible **phase 3** — CM repos, Postgres, CM server + agents, license/trial |
| `CDH_BASE` | Ansible **phase 4** — Auto-TLS, Kerberos, CMS, LDAP, CDH base cluster |
| `ECS_INSTALL` | Ansible **phase 5** — ECS / Data Services (requires base cluster) |

**Your example:** `VALIDATE,TERRAFORM,PREREQS,IDENTITY,CM_INSTALL` = validate → provision VMs → Ansible phases 1–3 (through Cloudera Manager install).

**Examples:**

| Goal | Checkboxes |
|---|---|
| Validation only | `VALIDATE` |
| Create machines only | `VALIDATE`, `TERRAFORM` |
| Prerequisites only | `VALIDATE`, `PREREQS` |
| CM install only | `VALIDATE`, `CM_INSTALL` |
| Terraform + CM | `VALIDATE`, `TERRAFORM`, `CM_INSTALL` |
| CM + CDH base | `VALIDATE`, `TERRAFORM`, `PREREQS`, `IDENTITY`, `CM_INSTALL`, `CDH_BASE` |
| Full stack (through ECS) | `VALIDATE`, `TERRAFORM`, `PREREQS`, `IDENTITY`, `CM_INSTALL`, `CDH_BASE`, `ECS_INSTALL` |

Ansible-only stages (no `TERRAFORM`) require existing `ansible-playbooks/inventory.ini`.

Multiple Ansible checkboxes run **sequentially** (e.g. `PREREQS` + `CM_INSTALL` runs phase 1 then phase 3).

## Validation checkboxes (`VALIDATION_CHECKS`)

Used only when `PIPELINE_STAGES` includes **`VALIDATE`**. Example: `TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY,EMAIL_FORMAT`.

| Checkbox | Check |
|---|---|
| `TOOLS` | Required CLI tools on the agent (`git`, `jq`, `python3`; adds `terraform` / `ansible-playbook` when those stages are selected) |
| `AWS_CREDS` | `aws sts get-caller-identity` (credentials user or instance role) |
| `TFVARS` | Tfvars file exists; `ENVIRONMENT`, `OWNER`, `AWS_REGION` load; AWS keypair/SG checks if `TERRAFORM` is also selected |
| `ANSIBLE_SYNTAX` | `ansible-playbook --syntax-check` on all numbered playbooks |
| `INVENTORY` | `ansible-playbooks/inventory.ini` present (required for Ansible-only runs; auto-enabled if you skip `TERRAFORM` but select Ansible stages) |
| `EMAIL_FORMAT` | `NOTIFICATION_EMAIL` is a valid address when non-empty |

`INVENTORY` is auto-added to validation when Ansible stages run without `TERRAFORM`.

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
| `ANSIBLE_GROUP_VARS_YAML` | Ansible-only YAML overrides (allowed keys in `jenkins/ansible-group-vars-allowed-keys.yaml`) — not full `all.yml` |
| `CM_REPO_USERNAME` | Optional archive.cloudera.com username (empty = skip; no early validation failure) |
| `CM_REPO_PASSWORD` | Optional archive.cloudera.com password (empty = skip) |
| `CM_LICENSE_CONTENT` | Optional multiline Cloudera license file content when no `*license*` file on the agent (empty = trial or agent file) |
| `MONITORING_STACK_ENABLED` | When checked (default), sets Ansible `monitoring_stack_enabled: true` for playbook `28` (Grafana/Prometheus/Alertmanager/cAdvisor). Uncheck to skip. Overrides `monitoring_stack_enabled` in `ANSIBLE_GROUP_VARS_YAML` if both are set. |

**Deployment portal (playbook 28):** open the index on the ops host **public** `ansible_host` (e.g. `http://<EIP>:8088/`). Private-IP URLs on the index page work only from hosts in the same VPC (ipaserver, cldr-mngr, cluster nodes). Ensure SG allows **8088**, **5050**, **8089** from your Jenkins/office CIDRs.

## Ansible group_vars override (`ANSIBLE_GROUP_VARS_YAML`)

Jenkins `text` parameters render as a **multiline text area**. Only **Ansible-only** keys are accepted (domain, passwords, CM/CDH/ECS versions, java/postgres/jdbc/psycopg, etc.) — not the full `all.yml` and not Terraform/Jenkins UI fields.

- Allowed keys: `jenkins/ansible-group-vars-allowed-keys.yaml`
- Examples: `jenkins/ansible-group-vars.example.yaml`
- Merged at runtime via `ansible-playbooks/jenkins_override.yml` + `-e @file` (not committed; never under `group_vars/all/`).
- Disallowed or unknown keys fail validation when Ansible stages are selected.
- CM archive login: use `CM_REPO_USERNAME` / `CM_REPO_PASSWORD` (not the textarea).

## License and CM archive credentials

For **CM_INSTALL** and later, Ansible resolves archive credentials from (first match wins):

1. Jenkins `CM_REPO_USERNAME` + `CM_REPO_PASSWORD` (both must be set; either empty is ignored)
2. `ansible-playbooks/*info.txt` with `login:` / `password:` lines on the agent
3. `cm_repo_username` / `cm_repo_password` in `group_vars/all.yml` or `ANSIBLE_GROUP_VARS_YAML`

Optional Jenkins CM creds do **not** fail validation or prereq stages when left empty.

License file (optional — CM can use trial):

1. Jenkins `CM_LICENSE_CONTENT` textarea (written to `jenkins/artifacts/cm-license.txt` at runtime)
2. `ansible-playbooks/*license*` or `license.txt` on the agent

**PREREQS** and **IDENTITY** never need license or archive creds.

## Email notifications

Success/failure emails (Email Extension plugin) include:

- **SSH private key** (`*.pem`) attached from `jenkins/artifacts/`
- **`cm-access.txt`** — CM HTTP/HTTPS URL, admin username/password, SSH example
- Build summary, inventory, and stage logs

Set `NOTIFICATION_EMAIL` or rely on `BUILD_USER_EMAIL`. CM credentials come from `group_vars/all.yml` (and Jenkins `ANSIBLE_GROUP_VARS_YAML` overrides when set).

## Artifacts

| File | Content |
|---|---|
| `build-summary.txt` | Stages, instance counts, inventory |
| `cm-access.txt` | SSH PEM path, CM URL, CM login (after CM_INSTALL) |
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
| `SG_MODE` | `CREATE_NEW` | Terraform creates SG — set `SG_NAME`, `ALLOWED_CIDRS`, `ALLOW_ALL` |
| `CREATE_EIP` | `true` | Elastic IP for Cloudera Manager |

#### Terraform combinations (`VPC_MODE` × `SG_MODE`)

Jenkins maps UI choices to Terraform `create_vpc` / `create_new_sg` in `apply_jenkins_pipeline_defaults()`. EC2 instances always use `module.vpc.vpc_id` and `module.security_group.security_group_id` (new or existing). `CREATE_EIP` is independent.

| `VPC_MODE` | `SG_MODE` | Supported | Behavior |
|---|---|---|---|
| `USE_DEFAULT` | `USE_EXISTING` | Yes (typical) | Default VPC + lookup SG by `EXISTING_SG_NAME` or `sg-*` in that VPC. Pre-validate checks SG exists in default VPC. |
| `USE_DEFAULT` | `CREATE_NEW` | Yes | Default VPC + Terraform creates `{ENVIRONMENT}-pvc_cluster_sg` (or `SG_NAME`). |
| `CREATE_NEW` | `CREATE_NEW` | Yes (greenfield) | New VPC + new SG in that VPC. |
| `CREATE_NEW` | `USE_EXISTING` | Conditional | SG must already exist **inside the new VPC** (name or `sg-id`). **Not** for first-time VPC create unless you import a pre-created SG — prefer `CREATE_NEW` for both on first run. |

**Not supported:** attaching to a **non-default existing VPC** without creating it (`VPC_MODE` has only `USE_DEFAULT` or `CREATE_NEW`).

**Account requirement:** `USE_DEFAULT` needs a default VPC in `AWS_REGION` (some accounts disable it).

Naming suffix in `.tfvars.yaml`: `sg_name_suffix: pvc_cluster_sg` → `{ENVIRONMENT}-pvc_cluster_sg`.

If `USE_EXISTING` fails (SG not in VPC), switch to **SG_MODE=CREATE_NEW** or set **EXISTING_SG_NAME** to a valid `sg-xxxxxxxx` ID.

### Security group ingress rules

**Default (`ALLOW_ALL=false`, recommended):** One inbound rule — **All traffic** (protocol `-1`, ports 0–0) from **ALLOWED_CIDRS** only. Set office/Jenkins agent IPs as `/32` in **ALLOWED_CIDRS**. This restricts **who** can connect, not **which ports** — every allowed source can use any protocol/port (SSH, CM UI, Kerberos, etc.).

**Open to world (`ALLOW_ALL=true`):** One inbound rule — **All traffic** from **0.0.0.0/0** (ignores **ALLOWED_CIDRS** for external ingress). Again, **all ports** from the internet — not a port whitelist.

**Jenkins settings (`SG_MODE=CREATE_NEW`):**

| Parameter | Recommended | Notes |
|---|---|---|
| `ALLOW_ALL` | **unchecked** (`false`) | All protocols/ports from **ALLOWED_CIDRS** only |
| `ALLOWED_CIDRS` | Your office/Jenkins IPs as `/32` | Include Jenkins agent egress IP for Ansible SSH; JSON array |
| `ALLOWED_PORTS` | *(ignored by Terraform)* | Does **not** limit ingress when `ALLOW_ALL` is true or false. Default `[22,443,80,7180,7183,7182]` is for tfvars compatibility / documentation of common CM ports only |
| `CLDR_EIP_NAME` | empty → `{ENVIRONMENT}-cldr-mngr-eip` | Name tag for CM Elastic IP when `CREATE_EIP=true`; unrelated to SG port rules |

**If you need port-only ingress (e.g. TCP 22 + 7180 only):** the pipeline’s `CREATE_NEW` SG module does not support that via **ALLOWED_PORTS**. Use **SG_MODE=USE_EXISTING** with a hand-tuned SG in AWS, or extend `terraform-code/cloudera-pvc-terraform/modules/security-group/`.

**Examples:**

```
ALLOWED_CIDRS=["137.83.231.109/32","54.254.32.236/32"]   # compact JSON — no spaces after commas
```

`.tfvars.yaml` uses the same compact format:

```yaml
allow_all: false
allowed_cidrs: '["137.83.231.109/32", ...]'
```

**Fix existing SG:** Re-run the Jenkins **TERRAFORM** stage on latest `main` with `SG_MODE=CREATE_NEW` and the settings above. Terraform updates ingress rules in place when the SG is already in state (see [Re-run same environment](#re-run-same-environment-ptgty-etc)). Console should show `[tfvars] Security group: allow_all=false allowed_cidrs=[...]` in the log.

**Verify in AWS:** Inbound rules should show **All traffic** (`-1`) from your CIDRs (or `0.0.0.0/0` when `ALLOW_ALL=true`), not per-port TCP rules or a useless TCP rule on port 0.

### Terraform state on Jenkins (holautosa — PSEAutomation pattern)

Jenkins uses **`CleanBeforeCheckout`** — the workspace is wiped each build. State is **not** stored in S3.

Following [PSEAutomation DeployHoL](https://github.com/cloudera/PSEAutomation/blob/main/OnCloud/AWS/build/Jenkinsfile.DeployHoL), persistent files live under holautosa:

```
/home/holautosa/HOL_AUTO_EXEC_DIR/cdp-onprem-automation/<ENVIRONMENT>/
  terraform/   # terraform.tfstate, terraform.tfstate.d/, *.pem
  ansible/     # inventory.ini, sshkey.pem
```

Each build restores state from holautosa before Terraform/Ansible and persists it back after apply. No S3 backend bucket is created or required.

`state_manifest.json` under the environment dir records the last successful persist (build number, git commit, keypair name, PEM/inventory checksums, Terraform state serial). Ansible and Terraform stages log it at startup — use it to spot PEM/inventory drift between builds.

`.terraform/` (provider/module cache) is **not** persisted — `terraform init` recreates it each build. Jenkins logs should show `State restore v2 (state files only; no .terraform cache)`.

**Why mismatches still happen (and how we mitigate them):**

| Layer | What it holds | Failure mode |
|---|---|---|
| Jenkins workspace | Fresh git checkout every build | Anything not restored from holautosa is lost |
| holautosa | `terraform.tfstate`, `*.pem`, optional `inventory.ini` copy | PEM missing → SSH fails even when AWS keypair exists |
| AWS | Live EC2, keypairs, SG rules | Source of truth for running infra |
| Jenkins job params | Saved parameter values | Can disagree with tfvars until `REFRESH_JENKINSFILE=YES` |
| Inventory | Regenerated from Terraform **public** IPs | Stale private IPs if restore overwrote inventory (fixed: Ansible restore skips `inventory.ini`) |

Ansible-only runs now **restore Terraform state + init** before regenerating inventory, so holautosa remains the single source of truth across stage splits.

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
| Jenkins agent IP not in security group | Preflight logs `Jenkins/agent egress IP: …` — add that `/32` to **ALLOWED_CIDRS** when `SG_MODE=CREATE_NEW` and `ALLOW_ALL=false`, or update the existing SG for `USE_EXISTING`. |
| Wrong SSH key or permissions | Terraform PEM is copied to `ansible-playbooks/sshkey.pem` (mode `600`). Ansible connects as `ec2-user` (`group_vars/all.yml`) with `become`; `00_setup_ssh_preqs.yml` enables root login afterward. |
| Ansible-only run without Terraform | Run `VALIDATE` + `TERRAFORM` once, or ensure holautosa has current state and regenerate inventory manually: `./jenkins/scripts/regenerate-inventory-from-terraform.sh` |

**Preflight:** `jenkins/scripts/ansible-connectivity-preflight.sh` SSH-tests up to five hosts before playbooks run.

**CM credentials warning (phase 1–2):** `No CM archive credentials from env or *info.txt` is expected for `PREREQS` / `IDENTITY` — CM archive login is only required from phase 3 (`CM_INSTALL`) onward.

### Missing license or CM credentials (phase 3+)

| Symptom | Fix |
|---|---|
| `No license file found` | Place `*license*` in `ansible-playbooks/`, or let CM use trial license (`21_setup_cm_license.yml`) |
| CM repo download fails | Place `*info.txt` in `ansible-playbooks/`, or set `cm_repo_username` / `cm_repo_password` in `group_vars/all.yml` |

## Local testing

```bash
export BUILD_NUMBER=local PIPELINE_STAGES=VALIDATE VALIDATION_CHECKS=TOOLS,TFVARS
./jenkins/scripts/validate-prereqs.sh
```

See [main README](../README.md) for tfvars layout and Ansible phases.
