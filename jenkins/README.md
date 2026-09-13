# Jenkins Pipeline — CDP On-Prem Automation

Declarative pipeline with **checkbox stage selection**, **configurable validation checks**, and **REFRESH_JENKINSFILE** support.

## Required Jenkins plugins

| Plugin | Purpose |
|---|---|
| Pipeline | Declarative pipeline |
| [Extended Choice Parameter](https://plugins.jenkins.io/extended-choice-parameter/) | `PIPELINE_STAGES` and `VALIDATION_CHECKS` checkboxes |
| [Email Extension](https://plugins.jenkins.io/email-ext/) | Success/failure notifications |
| [AnsiColor](https://plugins.jenkins.io/ansi-color/) | Colored Ansible console (default) |

## Console output (colored Ansible by default)

### Operator guide: local terminal vs Jenkins

| | **Local** (`./pvc_setup.sh`, wrappers on your laptop) | **Jenkins** default (`ANSIBLE_CONSOLE_OUTPUT=FULL_COLORED`) | **Jenkins** opt-in `ANSIBLE_CONSOLE_OUTPUT=PLAIN_SUMMARY` |
|---|---|---|---|
| **Colors** | Full ANSI when stdout is a TTY (`ui.sh`, Ansible default callback) | Colored Ansible + phase headers via AnsiColor (`options.ansiColor`) | No raw `[1;33m` escapes — output is stripped and/or plain callback |
| **Phase / playbook framing** | Colored `PHASE:` / `PLAYBOOK:` lines with Unicode or ASCII rules | Colored `PHASE:` / `PLAYBOOK:` headers when `UI_COLOR=1` | ASCII rules (`=`, `-`), plain wrapper labels |
| **Ansible task output** | Standard Ansible stdout (per-host) | Default Ansible callback — classic per-host `ok` / `changed` lines | `jenkins_plain`: summarized `ok`/`skipped` per task (or per-host with **ANSIBLE_PLAIN_PER_HOST_LINES**) |
| **Artifact logs** | Whatever you tee locally | Plain ASCII (ANSI stripped); console keeps color | Plain ASCII (ANSI stripped) |

**Build parameter:** **ANSIBLE_CONSOLE_OUTPUT** defaults to `FULL_COLORED` (classic Ansible with colors). Choose `PLAIN_SUMMARY` for summarized `jenkins_plain` output. Run **REFRESH_JENKINSFILE=YES** once after upgrading the Jenkinsfile.

**Plain but per-host (no color):** `PLAIN_SUMMARY` + **ANSIBLE_PLAIN_PER_HOST_LINES** = `true` (sets `JENKINS_ANSIBLE_VERBOSE_OUTPUT=1`).

**Manual override** (if you cannot refresh parameters yet): default colored mode uses `JENKINS_ANSI_CONSOLE=1`, `JENKINS_PLAIN_LOG=0`, `UI_COLOR=1`, `ANSIBLE_FORCE_COLOR=1`, and clears `NO_COLOR` / `ANSIBLE_NOCOLOR`.

**Do not** set `JENKINS_PLAIN_LOG=0` without AnsiColor and `JENKINS_ANSI_CONSOLE=1` — you may get raw escape sequences in the Blue Ocean / console log.

Self-tests: `jenkins/scripts/test-jenkins-ansi-pipe.sh`, `jenkins/scripts/test-jenkins-plain-callback.sh`.

---

Jenkins agents often show **raw ANSI** (`[1;33mPHASE:…`) when stdout is piped through `tee` without a working AnsiColor wrapper. The pipeline defaults to **colored Ansible on the console** (AnsiColor + default stdout callback). **Artifact logs** (`jenkins/artifacts/*.log`) are always plain ASCII via `jenkins_log_pipe`.

Stage wrappers (`run-ansible.sh`, `run-terraform.sh`) use `jenkins_log_pipe`, which calls `jenkins_prepare_log_output` when `BUILD_NUMBER`, `JENKINS_URL`, or `CI=true` is set. Colored mode leaves console ANSI intact; plain mode (`PLAIN_SUMMARY`) runs output through an ANSI stripper and sets `ANSIBLE_STDOUT_CALLBACK=jenkins_plain`.

Summarized plain console: set build parameter **ANSIBLE_CONSOLE_OUTPUT** to `PLAIN_SUMMARY`.

| Variable | Typical Jenkins value | Role |
|---|---|---|
| `ANSIBLE_CONSOLE_OUTPUT` | `FULL_COLORED` | Job parameter: `PLAIN_SUMMARY` enables `jenkins_plain` + stripped console |
| `JENKINS_PLAIN_LOG` | `0` (default) | `1` with `PLAIN_SUMMARY`: plain console; artifact logs always stripped |
| `JENKINS_ANSIBLE_VERBOSE_OUTPUT` | `0` | With `jenkins_plain`: per-host `ok`/`skipped` when `1` (**ANSIBLE_PLAIN_PER_HOST_LINES**) |
| `UI_COLOR` / `FORCE_COLOR` | `1` (default colored) | Wrapper labels (`ui_kv`, banners, `PHASE:` headers); `0` in plain mode |
| `ANSIBLE_FORCE_COLOR` / `PY_COLORS` | `1` (default colored) | Ansible/Pygments ANSI on console |
| `ANSIBLE_DISPLAY_OK_HOSTS` | `true` | `jenkins_plain` callback: one summarized `ok` line per task; `false` hides ok lines |
| `ANSIBLE_DISPLAY_SKIPPED_HOSTS` | `true` | Same for `skipped` hosts (one line per task, not per host); `false` hides skipped lines |
| `NO_COLOR` / `ANSIBLE_NOCOLOR` | `0` (default colored) | Set `1` in `PLAIN_SUMMARY` mode |
| `JENKINS_ANSI_CONSOLE` / `ANSIBLE_CI_CONSOLE` | `1` (default) | Colored Ansible + phase headers when AnsiColor wraps the stage |
| `JENKINS_SCRIPT_TTY` | unset | Legacy opt-in for local scripts without the log pipe |

Jenkins also sets (automatically): `BUILD_NUMBER`, `BUILD_ID`, `BUILD_URL`, `JOB_NAME`, `WORKSPACE`, `JENKINS_URL`, `NODE_NAME`, `EXECUTOR_NUMBER`, `CI=true`, and `TERM` (pipeline sets `xterm`).

Self-test: `jenkins/scripts/test-jenkins-ansi-pipe.sh`.

## Reload parameters after Jenkinsfile changes

1. Open **Build with Parameters**
2. Set **REFRESH_JENKINSFILE** = `YES`
3. Run the job — it aborts immediately after reloading the parameter UI
4. Run again with your desired stage checkboxes

Parameter help after **REFRESH_JENKINSFILE=YES**:

- **`PIPELINE_STAGES_REFERENCE`** — multiline **text** parameter (default = full stage table). Always visible on **Build with Parameters**; use this when Extended Choice long descriptions do not show in your Jenkins theme.
- **`PIPELINE_STAGES`** — short checkbox help line + per-option hints via Extended Choice `descriptionPropertyValue` (plugin-dependent; some UIs only show these in job configuration).
- Other parameters — `description` fields on boolean/string/choice params (security group, `ALLOWED_PORTS`, etc.).

**Copy-paste `PIPELINE_STAGES` (full deploy through ECS):**

```
VALIDATE,TERRAFORM,PREREQS,PORTAL,IDENTITY,CM_INSTALL,CM_TLS_KRB_LDAP,CDH_INSTALL,MONITORING,ECS_INSTALL
```

Optional tail stages (not in the line above): `STARTSTOP_AUTOMATION`, `DESTROY_STACK`. Default job checkboxes remain `VALIDATE,TERRAFORM,PORTAL,STARTSTOP_AUTOMATION` (see table below).

Each run also prints a **quick reference** in the console at **Resolve Stages** (see `echoPipelineStagesQuickReference` in the Jenkinsfile).

## Default parameter values

Defaults match `.tfvars.yaml` in the repo (refresh Jenkinsfile after updates):

| Parameter | Default |
|---|---|
| `PIPELINE_STAGES` | `VALIDATE,TERRAFORM,PORTAL,STARTSTOP_AUTOMATION` (not `CDH_INSTALL`, `MONITORING`, or `ECS_INSTALL`) |
| `DEPLOYMENT_PORTAL_ENABLED` | `true` (bootstrap Caddy portal when `MONITORING_STACK_ENABLED` and **PORTAL** stage selected) |
| `ECS_DATA_SERVICES_DEPLOY_ENABLED` | `false` (playbook 34 only when checked or an `ECS_DEPLOY_*` box is checked) |
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

If `PIPELINE_STAGES` is empty (old job config), the pipeline falls back to `VALIDATE,TERRAFORM,PORTAL,STARTSTOP_AUTOMATION`.

**Legacy token:** Saved jobs may still submit **`CDH_BASE`** — it expands to `CM_TLS_KRB_LDAP` + `CDH_INSTALL`. Run **REFRESH_JENKINSFILE=YES** after Jenkinsfile changes to reload checkboxes.

**Migrate old `PREREQS,IDENTITY,CM_INSTALL,CDH_BASE`:** check **`PREREQS,IDENTITY,CM_INSTALL,CM_TLS_KRB_LDAP,CDH_INSTALL`**. Add **`VALIDATE,TERRAFORM`** if you still provision EC2 (old string omitted them). **`PORTAL`** is auto-inserted when **`DEPLOYMENT_PORTAL_ENABLED=true`** (default) and you select identity/CM/CDH stages without checking PORTAL.

## Stage checkboxes (`PIPELINE_STAGES`)

Select one or more stage checkboxes. Fixed run order (each Ansible step is its own Jenkins stage in the UI):

`VALIDATE` → `TERRAFORM` → `PREREQS` → `PORTAL` → `IDENTITY` → `CM_INSTALL` → `CM_TLS_KRB_LDAP` → `CDH_INSTALL` → `MONITORING` → `ECS_INSTALL` → `STARTSTOP_AUTOMATION` → `DESTROY_STACK`

**Copy-paste (matches Jenkinsfile checkbox names):** `VALIDATE,TERRAFORM,PREREQS,PORTAL,IDENTITY,CM_INSTALL,CM_TLS_KRB_LDAP,CDH_INSTALL,MONITORING,ECS_INSTALL` — also at the top of **Build with Parameters** → `PIPELINE_STAGES` description and `PIPELINE_STAGES_REFERENCE` default text. Append `STARTSTOP_AUTOMATION` or `DESTROY_STACK` when needed.

| Checkbox | What runs |
|---|---|
| `VALIDATE` | `validate-prereqs.sh` — only checks selected in `VALIDATION_CHECKS` (no deploy) |
| `TERRAFORM` | EC2/VPC/SG/EIP via Terraform; `inventory.ini` + `.pem` key |
| `PREREQS` | Ansible **phase 1** — OS prereqs playbooks 01–09 |
| `PORTAL` | Bootstrap Caddy/pgAdmin/index (`10`); before CM when `DEPLOYMENT_PORTAL_ENABLED` |
| `IDENTITY` | Ansible **phase 2** — FreeIPA or AD; refreshes portal index (`35`) |
| `CM_INSTALL` | Ansible **phase 3** — CM repos, Postgres, CM server + agents, license/trial |
| `CM_TLS_KRB_LDAP` | Auto-TLS, CMS, LDAP, Kerberos (27→29→30→28); portal refresh |
| `CDH_INSTALL` | CDH base cluster (`31_setup_base_cluster.yml`); portal refresh |
| `MONITORING` | `32_setup_monitoring_stack.yml` (when `MONITORING_STACK_ENABLED`; needs `PORTAL`) |
| `ECS_INSTALL` | ECS cluster (`33`); optional `34_setup_ecs_data_services.yml` when `ECS_DATA_SERVICES_DEPLOY_ENABLED` |
| `STARTSTOP_AUTOMATION` | `run-ec2-startstop-automation.sh` — Ansible on **ipaserver** only; playbook **36** (deploy script) + **37** (run). See **EC2_STARTSTOP_*** params below. Requires Terraform **IAM instance profile** on ipaserver (`ipaserver_ec2_startstop_iam_enabled`, default true). |
| `DESTROY_STACK` | `run-destroy-stack.sh` — optional `99_cleanup.yml` (`CLEANUP_BEFORE_DESTROY`) then `terraform destroy` |

### STARTSTOP_AUTOMATION parameters

| Parameter | Default | Purpose |
|---|---|---|
| `PIPELINE_STAGES` → **`STARTSTOP_AUTOMATION`** | checked in job defaults | Enables stage **EC2 Start/Stop Automation** (after Ansible stages). If the checkbox is missing, run **REFRESH_JENKINSFILE=YES** once. |
| `EC2_STARTSTOP_DEPLOY_SCRIPT` | `true` | Ansible **36** — template `{prefix}_cldr_ec2_strt_stp.sh` to `/root/`, mode `0755` (+ awscli). Also runs at end of **IDENTITY** / `pvc_setup` phase 2. |
| `EC2_STARTSTOP_RUN_SCRIPT` | `false` | Ansible **37** — invoke deployed script with `EC2_STARTSTOP_OPERATION` / groups / environment (opt-in; default is deploy-only). Uncheck both deploy and run → validation error. |
| `EC2_STARTSTOP_OPERATION` | `describe` | `describe` \| `start` \| `stop` |
| `EC2_STARTSTOP_GROUPS` | *(empty)* | Comma-separated Terraform `instance_groups` keys → EC2 tag **`Group`**. Required for **start**/**stop** when run is enabled. |
| `EC2_STARTSTOP_CONFIRM` | `false` | Required for **stop** from Jenkins (non-interactive). Manual **stop** on ipaserver still prompts `yes`. |
| `ENVIRONMENT` | `development` | Maps to EC2 tag **`environment`** (same as `pvc_cluster_tags.environment` / `deployment_name_prefix`). |

**Jenkins vs manual on ipaserver:** Checking **`STARTSTOP_AUTOMATION`** runs the same script as SSH to ipaserver: `/root/<prefix>_cldr_ec2_strt_stp.sh <op> <environment> <group>…`. Jenkins sets `EC2_STARTSTOP_NON_INTERACTIVE=1` and `JENKINS_URL` so **stop** does not prompt; use **`EC2_STARTSTOP_CONFIRM=true`**. Manual runs use the ipaserver **instance IAM role** (Terraform-attached profile) — not Jenkins agent credentials.

**EC2 start/stop:** API calls filter **`tag:environment`** + optional **`tag:Group`** (matches Terraform tags on `module.ec2_instances`). Jenkins runs **start** / **describe** non-interactively; **stop** requires **`EC2_STARTSTOP_CONFIRM=true`**. Manual stop on ipaserver prompts `yes`.

**Destroy:** `DESTROY_STACK` requires **`DESTROY_STACK_CONFIRM`** unless **`DRY_RUN=true`** (destroy plan only, no apply).

**Your example:** `VALIDATE,TERRAFORM,PREREQS,IDENTITY,CM_INSTALL` = validate → provision VMs → Ansible phases 1–3 (through Cloudera Manager install).

**Examples:**

| Goal | Checkboxes |
|---|---|
| Validation only | `VALIDATE` |
| Create machines only | `VALIDATE`, `TERRAFORM` |
| Prerequisites only | `VALIDATE`, `PREREQS` |
| CM install only | `VALIDATE`, `CM_INSTALL` |
| Terraform + CM | `VALIDATE`, `TERRAFORM`, `CM_INSTALL` |
| CM + CDH base | `VALIDATE`, `TERRAFORM`, `PREREQS`, `PORTAL`, `IDENTITY`, `CM_INSTALL`, `CM_TLS_KRB_LDAP`, `CDH_INSTALL` |
| Full stack (through ECS) | All of the above + `MONITORING`, `ECS_INSTALL` |

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
| `GIT_BRANCH` | Branch to checkout — use **`main` at or after `691b943`** for PORTAL operator-access fixes (`deployment_portal_postgres_fqdn` and related localhost facts) |
| `NOTIFICATION_EMAIL` | Email recipient |
| `ANSIBLE_GROUP_VARS_YAML` | Ansible-only YAML overrides (allowed keys in `jenkins/ansible-group-vars-allowed-keys.yaml`) — not full `all.yml` |
| `CM_REPO_USERNAME` | Optional archive.cloudera.com username (empty = skip; no early validation failure) |
| `CM_REPO_PASSWORD` | Optional archive.cloudera.com password (empty = skip) |
| `CM_LICENSE_CONTENT` | Optional multiline Cloudera license file content when no `*license*` file on the agent (empty = trial or agent file) |
| `MONITORING_STACK_ENABLED` | When checked (default), sets Ansible `monitoring_stack_enabled: true` for playbook `28` (Grafana/Prometheus/Alertmanager/cAdvisor). Uncheck to skip. Overrides `monitoring_stack_enabled` in `ANSIBLE_GROUP_VARS_YAML` if both are set. |

**Deployment portal (playbook 10) and CM verify (25)** use two URL verification tiers (detail: `ansible-playbooks/docs/RUNBOOK.md` § Service URL verification tiers):

| Tier | Checks | Jenkins typical outcome |
|---|---|---|
| **A** (service host, **required**) | Ops: `127.0.0.1:<deployment_portal_http_port> (default 81)` + Caddy **Host** vhosts (portal, pgAdmin, IPA, Grafana/Prometheus/Alertmanager). CM: manager private IP / `ansible_host` / FQDN `:7180` on `cldr-mngr` (not Caddy) | Must pass or PORTAL / CM verify fails |
| **B** (Ansible controller, **public** profile) | GET printed external URLs (portal, CM, Grafana, IPA, ECS) from the agent | **`warn`** if SG blocks ports (`deployment_external_url_verify: warn`, default on Jenkins); per-service `deployment_cm_external_url_verify`, etc. |

Private-IP URLs on the index work only inside the VPC. Ensure SG allows **81** (`deployment_portal_http_port`), **5050**, **3000**/**9090**/**9093** (monitoring UIs), **8089** (cAdvisor), **7180**/**7183**, etc. from Jenkins/office CIDRs so Tier **B** succeeds. `access-urls.txt` (`build-access-urls.sh`) lists URLs for email; Ansible logs include `CDP_ACCESS_URLS_*` and Tier **B** warnings.

**Control-plane reachability (Jenkins vs VPN / bare metal):** The Jenkins agent has **no route** to VPC `10.x` / `172.31.x` addresses. `run-ansible.sh` exports `ANSIBLE_CONTROL_VIA_JENKINS=1`; `jenkins_override.yml` sets `ansible_control_reachability: public` so CM API and portal verify never treat inventory `private_ip` as the controller target (probes delegate to `cldr-mngr` at manager IP/FQDN where needed). For **bare metal** or **in-VPC/VPN** automation runners, use default `auto` or `ansible_control_reachability: private` in `ANSIBLE_GROUP_VARS_YAML` — Tier **B** is skipped when the effective profile is not `public`.

With **`caddy_vhost_enabled`**, the FreeIPA links use a lab hostname (`ipa.<ops-ip-dashed>.<base>`): default **`/ipa/modern-ui/`** plus legacy **`/ipa/ui`**. Caddy redirects `/` to modern UI and proxies **HTTP** to `<ipaserver-fqdn>` with **`Host`** and path-matched **`Referer`** upstream (cloudera-labs/openshift pattern). Playbook **10** (PORTAL stage) verifies tiers after sync; Tier **A** failures include Caddy log hints in the Ansible output.

## Ansible group_vars override (`ANSIBLE_GROUP_VARS_YAML`)

Jenkins `text` parameters render as a **multiline text area**. Only **Ansible-only** keys are accepted (domain, passwords, CM/CDH/ECS versions, java/postgres/jdbc/psycopg, etc.) — not the full `all.yml` and not Terraform/Jenkins UI fields.

- Allowed keys: `jenkins/ansible-group-vars-allowed-keys.yaml`
- Examples: `jenkins/ansible-group-vars.example.yaml`
- Merged at runtime via `ansible-playbooks/jenkins_override.yml` + `-e @file` (not committed; never under `group_vars/all/`).
- Disallowed or unknown keys fail validation when Ansible stages are selected.
- CM archive login: use `CM_REPO_USERNAME` / `CM_REPO_PASSWORD` (not the textarea).
- **Caddy edge port:** default **`deployment_portal_http_port: 81`** in `group_vars/all.yml` (portal/pgAdmin/monitoring/IPA vhosts). Do not paste legacy **`8088`** into the textarea. Jenkins `render-ansible-group-vars-override.py` rewrites **8088 → 81**. Open security group **81** from the Jenkins agent CIDR for portal Tier **B**; CM uses **7180**/**7183** on `cldr-mngr` (not Caddy).

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
- **`access-urls.txt`** — Portal, pgAdmin, Grafana, CM direct vs Caddy lab URLs (also embedded in build summary and email)
- Build summary, inventory, and stage logs

Set `NOTIFICATION_EMAIL` or rely on `BUILD_USER_EMAIL`. CM credentials come from `group_vars/all.yml` (and Jenkins `ANSIBLE_GROUP_VARS_YAML` overrides when set).

## Artifacts

| File | Content |
|---|---|
| `build-summary.txt` | Stages, instance counts, inventory |
| `cm-access.txt` | SSH PEM path, CM URL, CM login (after CM_INSTALL) |
| `access-urls.txt` | Portal / monitoring / Caddy / CM URLs (from Ansible `CDP_ACCESS_URLS_*` log block or inventory) |
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
| `No license file found` | Place `*license*` in `ansible-playbooks/`, or let CM use trial license (`26_setup_cm_license.yml`) |
| CM repo download fails | Place `*info.txt` in `ansible-playbooks/`, or set `cm_repo_username` / `cm_repo_password` in `group_vars/all.yml` |

## Local testing

```bash
export BUILD_NUMBER=local PIPELINE_STAGES=VALIDATE VALIDATION_CHECKS=TOOLS,TFVARS
./jenkins/scripts/validate-prereqs.sh
```

See [main README](../README.md) for tfvars layout and Ansible phases.
