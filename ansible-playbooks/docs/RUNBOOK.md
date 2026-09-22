# Deployment Runbook

Short operator path for deploying Cloudera Private Cloud. Use the linked
documents for configuration details and troubleshooting:

| Document | Use it for |
|---|---|
| [CONFIGURATION.md](CONFIGURATION.md) | Every `config.yml` option, accepted values, behavior, and AD credential inputs |
| [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) | Controller/network scenarios, FreeIPA and AD procedures, portal verification, recovery, and troubleshooting |
| [REFERENCE.md](REFERENCE.md) | Playbooks, variables, inventory groups, repositories, services, and cleanup controls |
| [RUN_ORDER.md](RUN_ORDER.md) | Exact playbook and Jenkins execution order |
| [VARIABLE_CONTRACTS.md](VARIABLE_CONTRACTS.md) | Maintainer-facing variable precedence and API/delegation contracts |
| [../../jenkins/README.md](../../jenkins/README.md) | Jenkins parameters and copy-ready stage combinations |

All commands below run from `ansible-playbooks/`:

```bash
cd ansible-playbooks
```

## 1. Prepare configuration

For an Ansible-only deployment, copy and edit the inventory template:

```bash
cp inventory.example.ini inventory.ini
vi inventory.ini
vi config.yml
```

Terraform deployments generate `inventory.ini`; still review `config.yml`
before running Ansible.

- Put deployment settings in [`config.yml`](../config.yml).
- Keep stable defaults and derived values in
  [`group_vars/all.yml`](../group_vars/all.yml).
- Keep passwords outside Git in Ansible Vault, Jenkins credentials, or a
  separate extra-vars file.
- Place the SSH key in this directory, use `~/.ssh/id_rsa`, or export
  `ANSIBLE_PRIVATE_KEY=/path/to/key.pem`.
- Supply CM archive credentials through `CM_INFO_FILE`,
  `CM_REPO_USERNAME`/`CM_REPO_PASSWORD`, Vault, or Jenkins credentials.

## 2. Validate access

```bash
ansible all -i inventory.ini -m ping -e @config.yml
./run-playbook.sh 00_setup_ssh_preqs.yml --check
```

Use `ansible_host` for the controller-reachable SSH address, `private_ip` for
cluster traffic, and optional `public_ip` for public links. See
[controller and network scenarios](OPERATIONS_GUIDE.md#running-from-any-controller-jenkins-ec2-bare-metal-laptop)
when using Jenkins, VPN, bare metal, macOS, or IPAServer as the controller.

## 3. Run the deployment

Full deployment:

```bash
DEPLOY_PHASE=all ./pvc_setup.sh
```

Phased deployment:

| Phase | Scope | Command |
|---|---|---|
| 1 | Prerequisites (`00`-`09`) | `DEPLOY_PHASE=1 ./pvc_setup.sh` |
| 2 | Identity and DNS (`11`-`12`) | `DEPLOY_PHASE=2 ./pvc_setup.sh` |
| 3 | PostgreSQL and Cloudera Manager (`20`-`26`) | `DEPLOY_PHASE=3 ./pvc_setup.sh` |
| 4 | Auto-TLS, CMS, LDAP, Kerberos, CDH (`27`-`31`) | `DEPLOY_PHASE=4 ./pvc_setup.sh` |
| 5 | ECS and optional data services (`33`-`34`) | `DEPLOY_PHASE=5 ./pvc_setup.sh` |

### Recommended CM security + First Run order (plays 27 → 30 → 31)

Run **CM_TLS_KRB_LDAP** before **CDH_INSTALL**. Do not start CM **First Run** from the UI while playbook **31** is running (both call `POST .../commands/firstRun` — double-run risk).

| Step | Playbook / sub-step | CM API or behavior | vs CM First Run wizard |
|------|---------------------|--------------------|-------------------------|
| 1 | **27** `27_setup_cm_autotls.yml` | `generateCmca`, CM/agent TLS | Before cluster exists |
| 2 | **28** CMS, **29** LDAP, **30** KDC import | CMS, LDAP, `importAdminCredentials` | KDC admin creds in CM before cluster |
| 3 | **31** (imports **27** idempotently) | `cloudera.cluster.cluster` create + service config | Cluster + roles in CM |
| 4 | **31** Knox reconcile | DB, master secret, `gateway-site` safety valve, Knox service `kerberos.auth.enabled`, Auto-TLS client truststore | Before Knox starts in First Run |
| 5 | **31** `prepare_cluster_kerberos_before_start` | `configureForKerberos`, `generateCredentials` | Matches “wait for Kerberos credentials” before service start |
| 6 | **31** `enable_base_cluster_autotls_api` | `configureAutoTlsServices` | After Kerberos, before any service start |
| 7 | **31** `POST .../commands/firstRun` | CM starts ZK → HDFS → Ranger → Knox → … → **Ozone last** | Do not run UI First Run in parallel |
| 8 | **31** post-start | Knox CDP proxy descriptor verify, marker, CMS restart, ZK assert | After First Run completes |

Interrupted First Run recovery in **31** starts ZK/HDFS/Ranger only (no `firstRun`), then ordered Ozone SCM → leader → remaining Ozone roles. See [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) (Run Phase 4 / base cluster).

If **31** failed before First Run (for example Knox `kerberos.auth.enabled` HTTP 400 on a role group), the cluster may exist with an unformatted NameNode. Re-run **31** after the fix: when the CM initialization marker is missing and HDFS is not `STARTED/GOOD`, **31** submits First Run automatically. Do not run the CM UI First Run wizard in parallel.

Run one playbook:

```bash
./run-playbook.sh 27_setup_cm_autotls.yml
```

Dry run:

```bash
DRY_RUN=true ./pvc_setup.sh
```

For Jenkins, select or paste one of the documented
[`PIPELINE_STAGES` combinations](../../jenkins/README.md#stage-checkboxes-pipeline_stages).

## 4. Verify

```bash
./run-playbook.sh 25_verify_cm.yml
./run-playbook.sh 35_refresh_deployment_portal.yml
```

Review the final `CDP_ACCESS_URLS` block or the Jenkins
`jenkins/artifacts/access-urls.txt` artifact. Detailed service checks are in
[Service URL verification](OPERATIONS_GUIDE.md#service-url-verification-portal-stack--cloudera-manager).

## 5. Cleanup

For a cluster service-data reset that preserves CM, agents, packages, parcels,
CSDs, caches, repositories, and agent host UUIDs:

```bash
cd ansible-playbooks
./cleanup-cluster-services.sh --scope all          # preview
./cleanup-cluster-services.sh --scope all --execute
./cleanup-cluster-services.sh --scope all --remove-service-lib-dirs --execute
```

The ECS scope is a destructive rebuild. It validates configured ECS storage
mounts before stopping or deleting anything and refuses mounted paths.

Preview cleanup:

```bash
./run-playbook.sh 99_cleanup.yml --check
```

Run only the cleanup scopes explicitly enabled in `config.yml` or extra vars:

```bash
./run-playbook.sh 99_cleanup.yml -e cleanup_e2e=true
```

Review all destructive switches before execution in
[Cleanup controls](REFERENCE.md#cleanup-99_cleanupyml) and the
[detailed cleanup procedure](OPERATIONS_GUIDE.md#cleanup-runbook).

## Failure path

1. Re-run the failed numbered playbook with `./run-playbook.sh`.
2. Confirm inventory SSH addresses and `ANSIBLE_PRIVATE_KEY`.
3. Check the failed task's CM, PostgreSQL, FreeIPA, DNS, or repository
   prerequisite in [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md#troubleshooting).
4. Use [REFERENCE.md](REFERENCE.md) for the exact variable or playbook
   contract; do not bypass failed preflight or verification tasks.
