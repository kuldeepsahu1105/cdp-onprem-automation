# ECS data services (CDW, CDE, CAI, Model Registry)

Playbook `34_setup_ecs_data_services.yml` enables Cloudera Data Services on an existing ECS private-cloud environment using **`cloudera.cloud`** (see `requirements.yml`, pinned commit reporting collection `3.3.0`) and the **CDP CLI** (`cdpcli` / `cdpy`).

The controller prerequisite task pins `cdpcli==0.9.164` from the configured
Python package index because that release exposes the private-cloud LDAP IAM
operations used by post-install automation. It installs the CLI in the dedicated
versioned virtual environment `ecs_cdp_cli_venv_path`, which defaults beneath
`ecs_persistent_state_dir` (`CDP_STATE_DIR` in Jenkins). This keeps the CLI in
the same writable `holautosa` state location as the credential cache instead of
deriving a path from workspace ownership. The task verifies that exact
executable before API changes, so an older or inconsistent system-wide `cdp`
cannot be selected. Cloudera Labs `cdpy` is pinned to Git tag `v2.1.0` with
`--no-deps` inside the same isolated virtual environment, avoiding similarly
named or stale packages in private indexes. Data-service module imports run
from an equivalent isolated runtime on the ECS master so `cloudera.cloud` can
always import `cdpy` and the REST client's `cryptography` signing dependency
where private control-plane DNS is resolvable. The controller runtime remains
available for standalone CLI and credential-bootstrap work.
Collection bootstrap also verifies that the effective
`cloudera.cloud.dw_cluster` module exposes the pinned commit's `private_cloud`
option. The former `v2.5.1` pin did not provide that option. If Jenkins has an
older collection that merely provides the module name, automation
force-installs the exact Git commit from `requirements.yml` instead of
accepting the incompatible copy.
The temporary ECS-master runtime exports both the legacy CLI profile variables
and the collection 3.3 REST-client variables (`CDP_CREDENTIALS_PATH` and
`CDP_ENDPOINT_URL`). Without the latter pair, CDW, CDE, and CAI module
operations exit before submitting requests because the new modules do not parse
`CDP_CONFIG_FILE` or `CDP_SHARED_CREDENTIALS_FILE`. Running these modules on
the external Jenkins controller is unsupported because private names such as
`console-cdp.apps.<cluster-domain>` resolve only inside the ECS network.
The ECS-master CDPy install uses the pinned GitHub tag archive over HTTPS rather
than a `git+` URL, so standalone ECS hosts do not require the `git` executable.

ECS installation owns CoreDNS and wildcard DNS. Before changing the global
forwarder, playbook 34 idempotently ensures the authoritative FreeIPA A records
for Cloudera Manager, the ECS Management Console, the FreeIPA LDAP endpoint,
and the ECS application wildcard. It then tests each configured FreeIPA or AD
resolver directly with explicit A-record queries. A candidate is accepted only
when every required hostname returns its expected IPv4 answer. If no direct
candidate passes, `ecs_coredns_allow_node_resolver_fallback` permits only
ECS-node resolvers that pass the same tests. The playbook refuses to modify
CoreDNS when no candidate is proven. Verified upstreams replace the global
stanza with the minimal existing-Corefile form
`forward . <validated-upstreams>`; this deployment renders exactly
`forward . 172.31.76.102`. The applied ConfigMap is reread and asserted before
fresh Python probe pods perform IPv4-only resolution and independent TCP checks
to the already validated IPv4 address for Cloudera Manager on 7183 and LDAP on
636. No Data Services API call occurs until those checks pass.

When Jenkins selects both `ECS_POST_INSTALL_TASKS` and `ECS_DATA_SERVICES`, LDAP
provider/admin IAM convergence runs only in post-install. The Data Services
stage does not repeat it. Data Services also no longer runs the Cloudera Manager
endpoint/client discovery chain because its `cloudera.cloud` modules communicate
with the ECS control plane through the isolated CDP CLI profile.

CDW, CDE, and CAI use the same `cloudera.cloud` request fields as the supplied
Cloudera Labs examples, adapted only for collection 3.3 option names. Matching
the supplied separate Labs playbooks, playbook 34 completes each selected
service before launching the next one: CDW and its catalog/Virtual Warehouses,
then CDE, then CAI and its TLS/UI follow-up. CDW and CAI submit with `wait: false` and use their structured
`dw_cluster_info` and `ml_info` APIs for bounded polling. This avoids remote
`async_wrapper` output corruption and exposes live service failures directly.
CDE retains its existing bounded Ansible async wrapper on this integration
branch. CAI adopts an existing healthy or in-progress workspace instead of
calling `createWorkspace` again. Because the workspace `instanceUrl` and
ListenerSet can appear before terminal installation status, automation first
polls until the endpoint is available, issues the proper FreeIPA wildcard
certificate, and creates `cml-tls-secret`; terminal workspace polling then
continues. If a user-initiated deletion is still propagating, preflight waits
for the backend record and name reservation to disappear. A terminal failed
workspace is reported without deletion or recreation.

The private CDE request uses the live API minimum of 26 CPU and 64 GiB with the
environment-specific scheduler parent `root.<environment>.cde`.
Before a rerun, CDE uses the signed `de list-services` summary, which does not
contact Cloudera Manager, to identify an existing terminal `*Failed` service.
Automation reports that service and fails only the CDE boundary; it does not
disable, delete, or recreate it. CDW and CAI apply the same non-destructive
terminal-failure policy. Healthy and in-progress resources remain eligible for
normal module adoption, and a user-initiated CAI deletion is allowed to finish
before a new workspace is submitted. Automation does not restart IAM/Liftie
deployments or delete control-plane datastore state.
Model Registry obtains Ozone S3
credentials from `ecs_model_registry_sdx_group` (default `sdx`) when that
optional override group has hosts; otherwise it automatically uses the first
host in `base_cluster_master_group`, where the standard base-cluster template
places the Ozone manager, SCM, and S3 Gateway roles. A missing Ozone-capable
inventory host is reported immediately but deferred to the final aggregate
assertion so CAI readiness and CDW follow-up diagnostics still run.
Each CDW, CDE, and CAI attempt has an independent failure boundary. A failed
service is recorded without preventing the next selected service from running,
and the final aggregate assertion fails only after all selected services and
successful-service follow-up work have been attempted. Model Registry remains
sequential because it has separate Ozone and environment prerequisites.
`ecs_data_services_status_wait_retries` and
`ecs_data_services_status_wait_delay` bound structured CDW/CAI polling.
`ecs_data_services_module_wait_timeout` remains the bound for cleanup calls
that use module-owned waits. The async settings remain only for CDE on this
integration branch. Failed CDW provisioning also collects pod status,
`hue-query-processor-0` description, and recent container logs from
`warehouse-<environment>` on the ECS master.

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
| `ecs_deploy_cai_registry: true` | `ECS_DEPLOY_CAI_REGISTRY` | Model Registry (uses `[sdx]` when populated, otherwise first base master) |

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
bundle path available on the ECS master. Raw signed Data Services calls,
including CDE service discovery and Model Registry list/create, use the same
isolated CLI prefix and TLS policy: a configured CA bundle takes precedence,
strict validation without a bundle uses the system trust store, and the
default non-strict mode passes `--no-verify-tls`.

The preferred environment name is the first IPA/domain label. If the healthy
control plane already contains exactly one environment (for example the
vendor-created `apps` environment), automation adopts it. If no environment
exists, automation creates the preferred private-cloud environment using the
configured CM cluster and credentials.

Machine-user and LDAP-admin IAM convergence reads existing tenant and
environment resource-role assignments first. Reruns invoke assignment APIs only
for missing roles, so already-converged users remain `ok` rather than producing
misleading `changed` results.

LDAP provider mutations and LDAP-admin IAM assignments run through an isolated
CDP CLI on the ECS master. This keeps the standalone playbook functional when
the Ansible controller or Jenkins cannot resolve or route to the private
`console-cdp` hostname. The FreeIPA CA is supplied to the IAM API as a protected
PEM certificate value, as required by the CLI array schema rather than as a
controller or remote file URI. Temporary profiles and automation credentials
are removed from the ECS master after the post-install block.

Generated machine-user credentials appear in the portal's authenticated
**Operator access** panel and remain in the controller cache with mode `0600`.
The portal entry identifies the machine user and environment and maps the
displayed username/password fields to `cdp_access_key_id`/`cdp_private_key`.
They are not attached to Jenkins email. Data-service URLs are persisted to the
catalog cache, restored during portal refresh, and included in the normal
portal/access-URL email report.

The controller cache location is selected automatically:

- Jenkins: `$CDP_STATE_DIR`, set by `jenkins/scripts/run-ansible.sh` beneath
  the workspace owner's real home, outside the Git checkout. This prevents
  `CleanBeforeCheckout` from deleting credentials and creating another access
  key on every rerun.
- Standalone runs: `$CDP_STATE_DIR` when explicitly set, otherwise
  `$XDG_STATE_HOME/cdp-onprem-automation/`, or
  `$HOME/.local/state/cdp-onprem-automation/` when `XDG_STATE_HOME` is unset.

Set `CDP_STATE_DIR` or override `ecs_persistent_state_dir` when another
persistent location is required. `CDP_ARTIFACTS_DIR` remains the location for
non-secret per-build logs and reports. The playbook reports the state path when
it creates or reuses the credential cache and does not generate a replacement
key while valid cached credentials are available.

Credential values are serialized with JSON-compatible YAML quoting so
multiline private keys remain intact. An unreadable legacy cache no longer
blocks deployment portal refresh. ECS post-install/Data Services automation
ignores an invalid cache and creates a replacement key only when no valid
explicit or cached credentials remain.

For ECS console revalidation, machine-user credentials, IAM/LDAP permissions,
and portal credential synchronization without reinstalling ECS, run:

```bash
DEPLOY_PHASE=8 ./pvc_setup.sh
```

The underlying standalone playbook is
`34_setup_ecs_post_install.yml`; the wrapper then runs
`35_sync_deployment_portal_access.yml`. The latter updates only
`operator-credentials.json` and the protected operator-access HTML fragment in
the existing portal. It does not run Docker Compose, pull images, recreate
Caddy or pgAdmin, or modify monitoring.

**List form** (unioned with flags):

```yaml
ecs_data_services_deploy_enabled: true
ecs_data_services_install: [cdw, cde, cai]  # model_registry for registry only
```

`model_registry` uses an Ozone-capable host for S3 credentials (Kerberos
`admin` / `common_password`). It prefers the optional **`[sdx]`** inventory
group when populated and otherwise selects the first host from
`base_cluster_master_group`.

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
| `ecs_ldap_admin_email` | (group_vars) | IAM display/lookup email for the LDAP admin; defaults to `<username>@<IPA domain>` |
| `ecs_ldap_admin_password` | (group_vars) | FreeIPA password (default `common_password`) |

LDAP admin IAM ensures the LDAP provider is the default identity provider,
creates or resolves the matching control-plane user record, and assigns roles
using its stable user CRN rather than the LDAP login name. Defaults select
administrative tenant and environment roles using
`ecs_ldap_admin_tenant_role_name_regex` and
`ecs_ldap_admin_resource_role_name_regex`; this excludes machine-user-only
tenant roles. Set `ecs_ldap_admin_assign_all_tenant_roles` or
`ecs_ldap_admin_assign_all_resource_roles_on_env` only when the target control
plane explicitly supports every returned role for human users.

The private control plane requires `identityProviderCrn` when creating an LDAP
user record, while `cdpcli==0.9.164` omits that newer field from its bundled
`CreateUserRequest` model. Automation creates a temporary per-run IAM model
override that adds only this field, invokes `create-user` with
`--identity-provider-crn`, and removes the override with the temporary profile.
It also preflights every CDP CLI operation used by LDAP/IAM post-install before
performing mutations.

Runs at the end of **`33_setup_ecs_cluster.yml`** when `ecs_ldap_*` is enabled, and in **`34_setup_ecs_data_services.yml`** (LDAP-only is allowed without CDW/CDE/CAI).

## Caddy ingress

Service UIs are proxied from the **deployment portal** host to the ECS master HTTPS ingress (`deployment_portal_Caddyfile_ecs_data_services.inc.j2`). Hostnames follow `*.{{ ecs_app_domain }}` (CDE/CAI service ids, `hue-<vw>.<ecs_app_domain>` for CDW).

Re-run `35_refresh_deployment_portal.yml` after changing catalog URLs if you skip the Caddy play in `34`.

The service lifecycle follows the Cloudera Labs patterns in
`cloudera-ce-aws-template` and `cloudera.exe`: each selected service is
completed before the next service starts. CDW and CAI submit with `wait: false`
and are observed through `dw_cluster_info` and `ml_info`; CDE retains the
integration branch's bounded async module job. Structured polling avoids remote
Ansible async-wrapper parsing failures for CDW/CAI and supports adoption of
existing resources. One service failure is retained for the final aggregate
report without preventing later selected services from running.

For CAI, playbook 34 first polls `ml_info` until `instanceUrl` appears or the
workspace reaches terminal `:failed`. It derives the workbench hostname from
that endpoint, ensures the FreeIPA `wildcard` certificate profile, issues a
wildcard certificate, and installs it as `cml-tls-secret` before continuing
bounded terminal-status polling. This ordering allows ListenerSet certificate
validation to complete without relying on a temporary self-signed secret.
The final probe accepts successful,
redirect, authentication-required, or forbidden responses. A persistent
ingress-default 404 fails the final aggregate check and prints the `cml`
namespace pods, services, ingresses, ingress description, and recent events.
Tune the bounded wait with `ecs_cai_ui_wait_retries` and
`ecs_cai_ui_wait_delay`; disable certificate automation with
`ecs_cai_configure_wildcard_tls: false` only when an external process manages
the namespace secret.

## Variables

See `group_vars/all.yml` (`ecs_cdw_*`, `ecs_cde_*`, `ecs_cai_*`, `ecs_model_registry_*`, `ecs_cdp_environment_name`). The preferred environment name is derived from the first IPA/domain label (for example, `cldrsetup.example` becomes `cldrsetup`). A healthy cluster with one existing vendor-created environment such as `apps` adopts that environment instead of creating a duplicate.

`ecs_coredns_forwarders` optionally overrides the direct DNS candidate list.
When empty, FreeIPA tries the first `ipaserver` private and Ansible addresses,
while AD uses `ad_dns_servers`. Every candidate must prove all required A
answers before use. `ecs_coredns_upstream_probe_retries` and
`ecs_coredns_upstream_probe_delay` bound that validation.
The tracked deployment configuration in `config.yml` explicitly selects
`172.31.76.102`; other deployments must replace or remove that deployment
override rather than changing the general empty default in
`group_vars/all.yml`.
`ecs_coredns_allow_node_resolver_fallback` controls whether non-loopback
nameservers from the ECS master's `/etc/resolv.conf` may be considered after
all inventory-derived direct candidates fail; fallback is not used when
`ecs_coredns_forwarders` is explicitly set. Every fallback candidate must pass
the identical A-record checks.

Terminal failed CDE services are reported from `de list-services` without
calling disable or delete. The CDE rescue boundary records the diagnostics,
later selected services still run, and the final aggregate assertion reports
the failure.

Before launching CDW, the playbook queries the control plane. Running and
in-progress clusters are adopted and monitored through `dw_cluster_info`
instead of calling `createPrivateCluster` again. Terminal `Error` or `Failed`
clusters are reported without deletion or recreation. The playbook does not
create or delete the CDW Hive service principal or its keytab; the Private
Cloud Data Warehouse control plane owns `hive/<hostname>@<realm>` creation and
key rotation.

The product-standard private-cloud CDW hostname is
`dwx-env-<environment>.cdp.local`, even when the deployment DNS domain and
Kerberos realm are different (for example, `cldr.internal.arpa` and
`CLDR.INTERNAL.ARPA`). Before CDW submission in FreeIPA deployments,
`ecs_cdw_ensure_freeipa_principal_host` idempotently ensures the external-name
FreeIPA host object, which provides
`host/dwx-env-<environment>.cdp.local@<cluster_realm>`. The configured
`ecs_cdw_freeipa_keytab_admin_principal` (default `ipaadmin_principal`) receives
additive permission to create and retrieve that host key and authenticates with
`ecs_cdw_freeipa_keytab_admin_password` (default
`krb5_kdc_admin_password`). Automation inspects the FreeIPA `Keytab` state and
invokes `ipa-getkeytab` without `-r` only when the host reports
`Keytab: False`, deleting the temporary keytab immediately afterward. Reruns
with `Keytab: True` do not invoke key generation, retrieval, or rotation. This
prerequisite does not create
`hive/dwx-env-<environment>.cdp.local@<cluster_realm>` or store a persistent
keytab; the Private Cloud Data Warehouse control plane owns the Hive service
principal and keytab lifecycle. Active Directory deployments skip this
FreeIPA-only step. An explicit `custom_kerberos_principal_hostname` in
`ecs_cdw_private_cloud_config` is honored by the same host prerequisite.

A gateway timeout from `createPrivateCluster` is treated as ambiguous:
automation continues structured discovery and accepts the recovered cluster
when the backend received the request. An already-exists response follows the
same adoption path.

`ecs_data_services_module_wait_timeout` bounds cleanup calls that retain
module-owned waits. `ecs_data_services_status_wait_retries` and
`ecs_data_services_status_wait_delay` bound CDW/CAI lifecycle polling. The
`ecs_data_services_async_*` values apply only to CDE on this branch.

## Not automated (Labs reference gaps)

- FreeIPA wildcard TLS for CDE-specific domains; CAI `cml-tls-secret` is automated.
- Prometheus ingress patches on ECS masters (reference `ecs_masters` plays).
- CDE environment-role permissions for end users.
