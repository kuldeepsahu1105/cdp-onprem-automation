# ECS data services (CDW, CDE, CAI, Model Registry)

Playbook `34_setup_ecs_data_services.yml` enables Cloudera Data Services on an existing ECS private-cloud environment using **`cloudera.cloud`** (see `requirements.yml`, git `v2.5.1`) and the **CDP CLI** (`cdpcli` / `cdpy`).

The controller prerequisite task pins `cdpcli==0.9.164` from the configured
Python package index because that release exposes the private-cloud LDAP IAM
operations used by post-install automation. It installs the CLI in the dedicated
versioned virtual environment `ecs_cdp_cli_venv_path` (by default
`<ecs_artifacts_dir>/.tools/cdpcli-0.9.164`) and verifies that exact executable
before making LDAP changes, so an older or inconsistent system-wide `cdp`
cannot be selected. Cloudera Labs `cdpy` is pinned to Git tag `v2.1.0` with
`--no-deps`, avoiding similarly named or stale packages in private indexes.

## Prerequisites

| Step | Playbook / action |
|------|-------------------|
| ECS experience cluster + control plane | `33_setup_ecs_cluster.yml` |
| Wildcard DNS `*.apps.<domain>` → ECS master | `19_setup_wildcard.yml` (FreeIPA) |
| Automation API access key | `ecs_auto_provision_api_access_key` + bootstrap key, or `ecs_api_*` |
| Deployment portal Caddy (optional ingress) | `10_setup_deployment_portal.yml` |

## Enable in Jenkins / group_vars

**Per-service flags** (recommended):

| Ansible | Jenkins parameter | Installs |
|---------|-------------------|----------|
| `ecs_deploy_cdw: true` | `ECS_DEPLOY_CDW` | CDW + Hive/Impala VWs |
| `ecs_deploy_cde: true` | `ECS_DEPLOY_CDE` | CDE |
| `ecs_deploy_cai: true` | `ECS_DEPLOY_CAI` | CAI (ML workspace) |
| `ecs_deploy_cai_registry: true` | `ECS_DEPLOY_CAI_REGISTRY` | Model Registry (`[sdx]` required) |

Turn on **`ecs_data_services_deploy_enabled`** (or **`ECS_DATA_SERVICES_DEPLOY_ENABLED`**) for the phase, or set any **`ECS_DEPLOY_*`** flag — playbook 34 runs when at least one service is selected.

On a healthy ECS control plane, automation reads the installer-generated signed
credential from Kubernetes secret `cdp/cm.creds`, field `cdp_keys.json`, and
uses it only to bootstrap the dedicated automation machine user. Secret values
are protected with Ansible `no_log`.

If that installer secret is unavailable, create one administrator access key in
Management Console and store it in Jenkins as a **Username with password**
credential:

- username: access-key ID
- password: private key

Set `ECS_IAM_BOOTSTRAP_CREDENTIAL_ID` to that fallback Jenkins credential ID.
Playbook 34 uses the installer or fallback key only to create
`cldr-automation-sa`, grants that machine user tenant
and effective-environment resource roles, creates its V2 access key, and caches
the generated credential with mode `0600`. Signed bootstrap CDP CLI calls and
their temporary profile run on the ECS master so private Management Console DNS
and ingress remain reachable from an external Jenkins controller; only the
resulting automation credential cache is written on the controller. Subsequent
runs use the automation key and do not require the administrator key. Running playbook 34 with
`ECS_DATA_SERVICES_DEPLOY_ENABLED=true` and no service selected performs only
this IAM bootstrap.

CDP CLI TLS verification follows `ecs_control_plane_validate_certs`. The default
`false` supports the installer-managed private console certificate. For strict
verification, set it to `true` and set `ecs_control_plane_ca_bundle` to a CA
bundle path available on the ECS master.

The preferred environment name is the first IPA/domain label. If the healthy
control plane already contains exactly one environment (for example the
vendor-created `apps` environment), automation adopts it. If no environment
exists, automation creates the preferred private-cloud environment using the
configured CM cluster and credentials.

LDAP provider mutations and LDAP-admin IAM assignments run through an isolated
CDP CLI on the ECS master. This keeps the standalone playbook functional when
the Ansible controller or Jenkins cannot resolve or route to the private
`console-cdp` hostname. Temporary profiles, automation credentials, and the
FreeIPA CA are removed from the ECS master after the post-install block.

Generated machine-user credentials appear in the portal's authenticated
**Operator access** panel and remain in the controller cache with mode `0600`.
The portal entry identifies the machine user and environment and maps the
displayed username/password fields to `cdp_access_key_id`/`cdp_private_key`.
They are not attached to Jenkins email. Data-service URLs are persisted to the
catalog cache, restored during portal refresh, and included in the normal
portal/access-URL email report.

The controller cache location is selected automatically:

- Jenkins/wrappers: `$CDP_ARTIFACTS_DIR`, normally
  `jenkins/artifacts/ecs-automation-api-credentials.yml`.
- Manual runs with `WORKSPACE`: `$WORKSPACE/artifacts/`.
- Other manual runs: `$XDG_STATE_HOME/cdp-onprem-automation/`, or
  `$HOME/.local/state/cdp-onprem-automation/` when `XDG_STATE_HOME` is unset.

Set `CDP_ARTIFACTS_DIR` or override `ecs_artifacts_dir` when another persistent
location is required. The playbook reports the path when it creates or reuses
the credential cache and does not generate a replacement key while valid
cached credentials are available.

Credential values are serialized with JSON-compatible YAML quoting so
multiline private keys remain intact. An unreadable legacy cache no longer
blocks deployment portal refresh. ECS post-install/Data Services automation
ignores an invalid cache and creates a replacement key only when no valid
explicit or cached credentials remain.

For ECS console revalidation, machine-user credentials, IAM/LDAP permissions,
and portal refresh without reinstalling ECS, run:

```bash
DEPLOY_PHASE=8 ./pvc_setup.sh
```

The underlying standalone playbook is
`34_setup_ecs_post_install.yml`; the wrapper adds `35_refresh_deployment_portal.yml`.

**List form** (unioned with flags):

```yaml
ecs_data_services_deploy_enabled: true
ecs_data_services_install: [cdw, cde, cai]  # model_registry for registry only
```

`model_registry` requires an **`[sdx]`** inventory group with Ozone S3 access (Kerberos `admin` / `common_password`).

## API endpoint

Signed API calls and the management console UI use **`https://<ecs_console_host_prefix>.<ecs_app_domain>`** (default **`console-cdp`**; `ecs_control_plane_url_effective` / `ecs_cdp_console_api_url_effective`). Override with `ecs_control_plane_url` or `ecs_cdp_console_api_url` when needed.

Generated CDP CLI profiles set `cdp_endpoint_url` to that console root and
set the legacy/Altus `endpoint_url` to the same root plus `/api/v1`. The latter
is required for private-cloud IAM commands; without it, CDP CLI falls back to
the public `iamapi.us-west-1.altus.cloudera.com` endpoint.

## Optional ECS LDAP and admin user

| Variable | Jenkins | Purpose |
|----------|---------|---------|
| `ecs_ldap_enabled` | `ECS_LDAP_ENABLED` | Sync FreeIPA/AD LDAP to ECS (`cm-ldap`) via `cdp iam` |
| `ecs_data_services_configure_ldap` | (group_vars) | Also sync LDAP when installing CDW/CDE/CAI in playbook 34 |
| `ecs_ldap_admin_user_enabled` | `ECS_LDAP_ADMIN_USER_ENABLED` | Create FreeIPA user **`{{ ecs_ldap_admin_user_prefix }}admin`** (default `cldradmin`) |
| `ecs_ldap_admin_user_prefix` | (group_vars) | Prefix before `admin` in the username |
| `ecs_ldap_admin_password` | (group_vars) | FreeIPA password (default `common_password`) |

LDAP admin IAM: by default assigns **all tenant IAM roles** (`ecs_ldap_admin_assign_all_tenant_roles: true`) and **all resource roles** on the ECS environment (`ecs_ldap_admin_assign_all_resource_roles_on_env: true`). Narrow with `ecs_ldap_admin_tenant_role_name_regex` / `ecs_ldap_admin_resource_role_name_regex` when those flags are false.

Runs at the end of **`33_setup_ecs_cluster.yml`** when `ecs_ldap_*` is enabled, and in **`34_setup_ecs_data_services.yml`** (LDAP-only is allowed without CDW/CDE/CAI).

## Caddy ingress

Service UIs are proxied from the **deployment portal** host to the ECS master HTTPS ingress (`deployment_portal_Caddyfile_ecs_data_services.inc.j2`). Hostnames follow `*.{{ ecs_app_domain }}` (CDE/CAI service ids, `hue-<vw>.<ecs_app_domain>` for CDW).

Re-run `35_refresh_deployment_portal.yml` after changing catalog URLs if you skip the Caddy play in `34`.

## Variables

See `group_vars/all.yml` (`ecs_cdw_*`, `ecs_cde_*`, `ecs_cai_*`, `ecs_model_registry_*`, `ecs_cdp_environment_name`). The preferred environment name is derived from the first IPA/domain label (for example, `cldrsetup.example` becomes `cldrsetup`). A healthy cluster with one existing vendor-created environment such as `apps` adopts that environment instead of creating a duplicate.

## Not automated (Labs reference gaps)

- FreeIPA wildcard TLS for per-service domains (CDE/CAI) — upstream TLS verify is disabled on Caddy → ECS master only.
- CoreDNS / Prometheus ingress patches on ECS masters (reference `ecs_masters` plays).
- CDE environment-role permissions for end users.
