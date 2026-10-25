# Deployment Runbook

Copy-ready commands for AWS and existing bare-metal nodes. See
[CONFIGURATION.md](CONFIGURATION.md) for variables and
[OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) for detailed troubleshooting.

## Before starting

Provide:

- Supported RHEL or Ubuntu nodes with working forward/reverse DNS and NTP.
- Root SSH or an SSH user with passwordless `become`.
- Cloudera archive credentials and an optional `license.txt`.
- Required network access between all cluster nodes.

Keep passwords outside Git in environment variables, Vault, Jenkins
credentials, or a protected extra-vars file.
Use the [operator editing checklist](CONFIGURATION.md#operator-editing-checklist)
for exact keys, required/conditional values, safe secret inputs and static
pre-run checks. In `vi`, press `i` to edit, `Esc` then `:wq` + Enter to
save/quit, or `:q!` + Enter to discard edits.

## AWS deployment

### 1. Download and configure

```bash
mkdir -p cdp-deployment && cd cdp-deployment

curl -fsSLO https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/main/clone_and_run_terraform.sh
curl -fsSLO https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/main/clone_and_run_pvc_automation.sh
curl -fsSLO https://raw.githubusercontent.com/kuldeepsahu1105/cdp-onprem-automation/main/.tfvars.yaml

chmod +x clone_and_run_*.sh
vi .tfvars.yaml

export AWS_PROFILE=my-aws-profile
cp /secure/path/license.txt .   # optional for trial deployments
```

Complete the [AWS parameter checklist](../../READme.adoc#operator-editing-checklist):
at minimum verify `aws_region`, `owner`, `environment`, `ami_id`,
`create_vpc`, `create_new_sg`, `create_keypair`, `create_eip`,
`existing_sg_name` / `existing_keypair_name` when reusing resources, and every
`instance_groups` entry's `count`, `instance_type`, `volume_size`.
For a new SG review `allow_all` and `allowed_cidrs` (`allowed_ports` is
ignored). The sample AMI, CIDRs, names and region are not universal defaults.

Check account and review a plan before provisioning:

```bash
aws sts get-caller-identity
DRY_RUN=true SHOW_TF_PLAN_OUTPUT=true ./clone_and_run_terraform.sh
```

This is plan-only, not offline: the wrapper may install tools, update its
checkout and initialize/reconcile Terraform state. It does not generate the
deployment inventory until a real apply.

### 2. Provision and deploy

```bash
./clone_and_run_terraform.sh
# The Terraform wrapper has now cloned the repository and generated inventory.
cd cdp-onprem-automation/ansible-playbooks
vi config.yml
```

Complete the [Ansible checklist](CONFIGURATION.md#operator-editing-checklist)
for identity/domain, versions/build IDs, services, credentials, TLS and optional
ECS/portal/monitoring. Inspect generated `inventory.ini` but never edit it.
Use an encrypted file outside the checkout for archive and deployment secrets:

```bash
umask 077
EDITOR=vi ansible-vault create /secure/path/deployment-secrets.vault.yml
export ANSIBLE_EXTRA_VARS='@/secure/path/deployment-secrets.vault.yml'
export ANSIBLE_VAULT_PASSWORD_FILE=/secure/path/vault-password
export ANSIBLE_PRIVATE_KEY=/secure/path/matching-private-key
```

Supply real paths; the protected Vault password file must already exist.
In the vault include `cm_repo_username`, `cm_repo_password` and applicable
password keys from the checklist. Do not put passwords directly in shell
commands. Run the static pre-run checks linked above before deployment.
Run `DEPLOY_PHASE=all ./pvc_setup.sh` for AWS, or use phased execution:

```bash
DEPLOY_PHASE=1          ./pvc_setup.sh # prerequisites
DEPLOY_PHASE=portal     ./pvc_setup.sh # portal/pgAdmin
DEPLOY_PHASE=2          ./pvc_setup.sh # identity/DNS
DEPLOY_PHASE=3          ./pvc_setup.sh # PostgreSQL/CM
DEPLOY_PHASE=cm_tls     ./pvc_setup.sh # TLS/CMS/LDAP/Kerberos
DEPLOY_PHASE=cdh        ./pvc_setup.sh # base CDH
DEPLOY_PHASE=monitoring ./pvc_setup.sh # monitoring
DEPLOY_PHASE=ecs        ./pvc_setup.sh # optional ECS
```

Use this local entry point after editing tracked `config.yml`; clone wrappers
fetch/checkout/pull a branch and can conflict with local edits.

## Bare-metal deployment

Terraform and AWS are not required. The Ansible controller must route to each
node's private management address, directly or through ProxyJump.

### 1. Prepare inventory

```bash
git clone https://github.com/kuldeepsahu1105/cdp-onprem-automation.git
cd cdp-onprem-automation/ansible-playbooks
cp inventory.example.ini inventory.ini
vi inventory.ini
vi config.yml
```

Example `inventory.ini`:

```ini
[ipaserver]
ipa-node ansible_host=10.54.75.10 private_ip=10.54.75.10 cldr_hostname=ipaserver

[cldr-mngr]
cm-node ansible_host=10.54.75.20 private_ip=10.54.75.20 cldr_hostname=cldr-mngr

[base-masters]
base-master ansible_host=10.54.75.30 private_ip=10.54.75.30 cldr_hostname=pvcbase-master

[base-workers]
worker1 ansible_host=10.54.75.31 private_ip=10.54.75.31 cldr_hostname=pvcbase-worker1
worker2 ansible_host=10.54.75.32 private_ip=10.54.75.32 cldr_hostname=pvcbase-worker2

# Keep both ECS groups defined even when ECS is not deployed.
[ecs-masters]

[ecs-workers]
```

Remove the `[ipaserver]` host when using existing Active Directory. Add a
`[postgres]` host only for a dedicated database node; otherwise PostgreSQL is
installed on `cldr-mngr`. Keep the empty `[ecs-masters]` and `[ecs-workers]`
headers when ECS has no hosts; ECS-aware tasks reference both groups.

### 2. Configure

Common `config.yml`:

```yaml
deployment_environment: baremetal
ansible_control_reachability: private
deployment_portal_access_profile: private
ansible_user: root
```

Add one identity configuration:

```yaml
# FreeIPA
identity_provider: freeipa
ipaserver_domain: cldrsetup.example.com
dns_forwarders: no-forwarders
```

```yaml
# Existing Active Directory
identity_provider: ad
ad_domain: corp.example.com
ad_kdc_host: 10.54.75.5
ad_dns_servers: [10.54.75.5]
ad_join_user: svc-cloudera-join
```

### 3. Validate

First run the [static pre-run checks](CONFIGURATION.md#pre-run-checks-in-order).
Then, from `ansible-playbooks/`, set the matching key and Vault inputs.
The following commands contact hosts; the check-mode command is not guaranteed
side-effect-free and is not part of the offline checks:

```bash
export ANSIBLE_PRIVATE_KEY=/secure/path/id_rsa
export ANSIBLE_EXTRA_VARS='@/secure/path/deployment-secrets.vault.yml'
export ANSIBLE_VAULT_PASSWORD_FILE=/secure/path/vault-password
cp /secure/path/license.txt .   # optional for trial deployments

ansible all -i inventory.ini -m ping -e @config.yml --private-key "$ANSIBLE_PRIVATE_KEY"
ansible-playbook -i inventory.ini detect_identity.yml -e @config.yml \
  -e @/secure/path/deployment-secrets.vault.yml --private-key "$ANSIBLE_PRIVATE_KEY"
./run-playbook.sh 00_setup_ssh_preqs.yml --check \
  -e @/secure/path/deployment-secrets.vault.yml --private-key "$ANSIBLE_PRIVATE_KEY"
```

Create the encrypted file as shown in the AWS section and include applicable
AD/FreeIPA, archive and service credentials from the checklist. The direct
playbook commands below also need
`-e @/secure/path/deployment-secrets.vault.yml --private-key "$ANSIBLE_PRIVATE_KEY"`
when those settings are not otherwise configured; `ANSIBLE_EXTRA_VARS` is
consumed by `pvc_setup.sh`, not by direct `ansible-playbook` or `run-playbook.sh`.

### 4. Deploy

Do **not** use `DEPLOY_PHASE=all`, `DEPLOY_PHASE=2`, or the portal wrapper on
bare metal: those paths currently install EC2 helper playbook **36**. Use:

```bash
DEPLOY_PHASE=1 ./pvc_setup.sh

# Optional portal
ansible-playbook -i inventory.ini 10_setup_deployment_portal.yml -e @config.yml

# Required identity; selects FreeIPA or AD
ansible-playbook -i inventory.ini 11_identity_setup.yml -e @config.yml

DEPLOY_PHASE=3          ./pvc_setup.sh # PostgreSQL and CM
DEPLOY_PHASE=cm_tls     ./pvc_setup.sh # TLS/CMS/LDAP/Kerberos
DEPLOY_PHASE=cdh        ./pvc_setup.sh # base CDH
DEPLOY_PHASE=monitoring ./pvc_setup.sh # optional monitoring
```

Exclude Terraform, Terraform destroy, playbooks **36** and **37**, and Jenkins
`STARTSTOP_AUTOMATION`. ECS additionally requires suitable bare-metal DNS,
Kubernetes, storage, load balancing, and sizing.

## Verify

From `ansible-playbooks/`:

```bash
./run-playbook.sh 25_verify_cm.yml
./run-playbook.sh 35_refresh_deployment_portal.yml # when portal is installed
```

CM API output should use the manager's private address on bare metal. Do not
start CM First Run manually while the `cdh` phase is running.

## Re-run a failed step

```bash
./run-playbook.sh 23_setup_postgres.yml
./run-playbook.sh 24_start_cm.yml
./run-playbook.sh 31_setup_base_cluster.yml
```

Fix the reported prerequisite rather than bypassing its assertion. Exact
phase order is in [RUN_ORDER.md](RUN_ORDER.md).
