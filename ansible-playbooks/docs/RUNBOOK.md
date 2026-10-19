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
export CM_REPO_USERNAME='archive-user'
export CM_REPO_PASSWORD='archive-password'
cp /secure/path/license.txt .   # optional for trial deployments
```

Review region, environment, versions, instance groups, sizing, volumes, key
pair, VPC, and allowed CIDRs in `.tfvars.yaml`.

### 2. Provision and deploy

```bash
./clone_and_run_terraform.sh
DEPLOY_PHASE=all ./clone_and_run_pvc_automation.sh
```

For phased execution:

```bash
DEPLOY_PHASE=1          ./clone_and_run_pvc_automation.sh # prerequisites
DEPLOY_PHASE=portal     ./clone_and_run_pvc_automation.sh # portal/pgAdmin
DEPLOY_PHASE=2          ./clone_and_run_pvc_automation.sh # identity/DNS
DEPLOY_PHASE=3          ./clone_and_run_pvc_automation.sh # PostgreSQL/CM
DEPLOY_PHASE=cm_tls     ./clone_and_run_pvc_automation.sh # TLS/CMS/LDAP/Kerberos
DEPLOY_PHASE=cdh        ./clone_and_run_pvc_automation.sh # base CDH
DEPLOY_PHASE=monitoring ./clone_and_run_pvc_automation.sh # monitoring
DEPLOY_PHASE=ecs        ./clone_and_run_pvc_automation.sh # optional ECS
```

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
```

Remove the `[ipaserver]` host when using existing Active Directory. Add a
`[postgres]` host only for a dedicated database node; otherwise PostgreSQL is
installed on `cldr-mngr`.

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

```bash
export ANSIBLE_PRIVATE_KEY=/secure/path/id_rsa
export CM_REPO_USERNAME='archive-user'
export CM_REPO_PASSWORD='archive-password'
cp /secure/path/license.txt .   # optional for trial deployments

ansible all -i inventory.ini -m ping -e @config.yml
ansible-playbook -i inventory.ini detect_identity.yml -e @config.yml
./run-playbook.sh 00_setup_ssh_preqs.yml --check
```

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
