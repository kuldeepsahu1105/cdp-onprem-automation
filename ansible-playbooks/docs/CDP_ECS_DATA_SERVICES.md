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
one fresh Python probe pod performs IPv4-only resolution for CM, the ECS
console, and LDAP when LDAP sync/admin is selected, all in the same resolver
context. It also performs independent TCP checks to the already validated IPv4
address for Cloudera Manager on 7183 and selected LDAP on 636. The pod logs its
`/etc/resolv.conf`, reports each FQDN separately, and
uses at most `ecs_data_services_dns_probe_attempts` attempts (default `3`).
Failed hostnames are retried after `ecs_data_services_dns_probe_retry_delay`
(default `31` seconds), which exceeds the managed CoreDNS `cache 30` negative
TTL so an NXDOMAIN observed during authoritative record convergence is not
replayed for every retry. Successful hostnames are removed from the pending
set and are not checked again. Kubernetes pod lifecycle polling remains
separate and uses `ecs_data_services_dns_probe_wait_delay`.
The separate pod wait bound covers Kubernetes scheduling and image startup; it
does not multiply DNS checks. No Data Services API call occurs until all checks
pass.

When Jenkins selects both `ECS_POST_INSTALL_TASKS` and `ECS_DATA_SERVICES`, LDAP
provider/admin IAM convergence runs only in post-install. The Data Services
stage does not repeat it. Data Services also no longer runs the Cloudera Manager
endpoint/client discovery chain because its `cloudera.cloud` modules communicate
with the ECS control plane through the isolated CDP CLI profile.

CDW, CDE, and CAI use the same `cloudera.cloud` request fields as the supplied
Cloudera Labs examples, adapted only for collection 3.3 option names. Matching
the supplied separate Labs playbooks, playbook 34 completes each selected
service before launching the next one: CDW and its catalog/Virtual Warehouses,
then CDE, then CAI and its TLS/UI follow-up. CDW and CAI submit with `wait: false`
and use their structured `dw_cluster_info` and `ml_info` APIs for bounded
polling. Definitive submission errors fail their service boundary immediately
with the original module/API message. Only documented ambiguous CDW responses
(`already exists`, `environment is already activated` with an existing cluster
id, HTTP 504, or timeout) proceed to structured discovery so the control plane
can prove whether the request landed. This avoids remote
`async_wrapper` output corruption and exposes live service failures directly.
CDE retains its existing bounded Ansible async wrapper on this integration
branch, but a completed async job that reports a module/API failure fails the
CDE boundary with that response before ingress or catalog registration. CAI adopts an existing healthy or in-progress workspace instead of calling
`createWorkspace` again. For TLS-enabled workspaces, automation derives the
stable endpoint from `ecs_cai_static_subdomain` and `ecs_app_domain`, creates
the namespace, and validates or converges `cml-tls-secret` **before**
submission. FreeIPA deployments issue the trusted base-host plus wildcard
certificate through the existing wildcard profile. AD, external-PKI, and
identity-provider-free deployments reuse a valid trusted secret or require
explicit controller-side certificate, key, and CA-bundle paths; automation
never creates a temporary/self-signed fallback. The secret must be
`kubernetes.io/tls`, the key must match, the certificate must be trusted,
unexpired for the configured minimum, and cover both the base endpoint and its
wildcard children. `createWorkspace` receives the same static subdomain and is
gated on successful secret validation. If a user-initiated deletion is still propagating, preflight waits
for the backend record and name reservation to disappear. A terminal failed
workspace is reported without deletion or recreation.

Fresh private CDE services default to 300 CPU and 1000 GiB with the existing
resource-pool API path `root.<environment>.cde`. When the environment already
has a healthy CDE service, automation reads its raw `de describe-service`
response and reuses the exact `resourcePool`, `cpuRequests`, and
`memoryRequests` strings accepted by that private-cloud control plane. This
avoids relying on the collection's lossy `de_info` resource mapping or on a
locally assumed memory-unit serialization. Explicit defaults remain the
standalone fallback when no healthy reference service exists. The UI displays
the final pool segment as `cde`, but private-cloud `enableService` rejects that
display label unless the fully qualified scheduler path is submitted. These
values apply only when creating a service; changing them does not resize an
existing CDE service. Existing healthy or provisioning services are reused
without resizing. Failed, deleted, or stale reserved names are retained and skipped;
the playbook selects the first available deterministic bounded name
(`name`, `name-2`, and so on), and records that effective name in the catalog.
After the service is ready, CDE also converges one default Virtual Cluster.
The base name, CPU, memory, and tier are configurable with
`ecs_cde_virtual_cluster_*`. Discovery uses the authoritative `de list-vcs`
`vcName` and `status` fields. `AppInstalled` and in-progress resources are
reused/waited; failed, deleted, deleting, or stale-reserved names are retained
and skipped in favor of the next deterministic suffix. The effective VC name,
status, and native `VcUiUrl` are recorded in the service catalog.
Before a rerun, CDE uses the signed `de list-services` summary, which does not
contact Cloudera Manager. Only explicit healthy or transitional service states
are eligible for mutation-free adoption. Failed, deleted, deleting, reserved,
or unknown-status names are retained without disable/delete and skipped in
favor of the next deterministic bounded suffix. The same explicit allowlist
policy applies to CDE Virtual Clusters. Existing adopted service capacity and
VC compute settings are never updated. Automation does not restart IAM/Liftie
deployments or delete control-plane datastore state.
Model Registry obtains Ozone S3
credentials from `ecs_model_registry_sdx_group` (default `sdx`) when that
optional override group has hosts; otherwise it automatically uses the first
host in `base_cluster_master_group`, where the standard base-cluster template
places the Ozone manager, SCM, and S3 Gateway roles. A missing Ozone-capable
inventory host is reported immediately but deferred to the final aggregate
assertion so CAI readiness and CDW follow-up diagnostics still run.
Creation also requires a human creator CRN because private-cloud CRP uses the
request-signing actor for the downstream workspace creator even when the
`createModelRegistry` payload contains `creatorCrn`. The effective creator is
`ecs_model_registry_creator_crn` when explicitly set, otherwise the unique
human `ecs_ldap_admin_user_crn` resolved by the LDAP admin lookup. Automation
requires a nonempty CRN containing `:user:`, rejects `:machineUser:`, creates a
temporary V2 access key for that human, and signs only the
`ml create-model-registry` request with it. The payload still includes
`--creator-crn` for API consistency. The temporary credential file and access
key are deleted in an Ansible `always` block after the request.
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

The non-secret Data Services catalog defaults to
`{{ playbook_dir }}/ecs-data-services-catalog.yml`, so Jenkins and direct
`ansible-playbook` runs use a controller-local path readable by the account
running Ansible. Override it with `CDP_DATA_SERVICES_CATALOG_PATH` or
`ecs_data_services_catalog_cache_path`. Portal refresh also reads the legacy
`{{ ecs_persistent_state_dir }}/ecs-data-services-catalog.yml` path when the new
path is absent and the legacy file is readable; inaccessible caches are skipped
instead of failing portal refresh.
The catalog is non-secret and is written with controller-readable permissions.
Portal fact construction reads it with Ansible `slurp` under local privilege
escalation, so a legacy/root-owned cache remains readable from Jenkins and
direct `ansible-playbook` runs.

Credential caches remain under `ecs_persistent_state_dir`: Jenkins uses
`$CDP_STATE_DIR`, while standalone runs use `$CDP_STATE_DIR` when set,
otherwise `$XDG_STATE_HOME/cdp-onprem-automation/` or
`$HOME/.local/state/cdp-onprem-automation/`. `CDP_ARTIFACTS_DIR` remains the
location for non-secret per-build logs and reports.

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

For CAI, playbook 34 first converges the trusted TLS secret for
`<ecs_cai_static_subdomain>.<ecs_app_domain>` and its wildcard children, then
submits `createWorkspace` with that same static subdomain. A valid existing
secret is reused without rotation. Invalid or temporary material is replaced
only through FreeIPA or explicitly configured external PKI inputs. Missing
trusted material fails before submission. After submission or adoption,
`ml_info` must return the same endpoint hostname before ListenerSet, terminal
status, and UI verification continue. An adopted endpoint mismatch fails
without changing the secret or recreating the workspace.
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

When CDW is selected, the playbook also provisions one Data Visualization.
`ecs_cdw_dataviz_name` controls its base name; `ecs_cdw_dataviz_user_groups`
and `ecs_cdw_dataviz_admin_groups` supply the required access configuration.
Private-cloud deployments may set `ecs_cdw_dataviz_resource_template` and
`ecs_cdw_dataviz_resource_pool`. Running resources are reused, transitional
resources are waited, and Failed, Error, or Deleting names are preserved while
the next deterministic bounded name is selected.
later selected services still run, and the final aggregate assertion reports
the failure.

Before launching CDW, the playbook queries the control plane. Running and
in-progress clusters are adopted and monitored through `dw_cluster_info`
instead of calling `createPrivateCluster` again. Terminal `Error` or `Failed`
clusters are reported without deletion or recreation. An existing cluster
whose status is exactly `Deactivated` (case-insensitive) fails preflight before
FreeIPA principal mutation or submission. The pinned `cloudera.cloud`
`dw_cluster` module does not reconcile or reactivate that state. In the
observed UI failure, the cluster-specific `t-shirt-sizes` endpoint returned
HTTP 404 (`404 page not found` / `NOT_FOUND_ERROR`), so the UI did not submit
the activation POST. Repair and use the supported DWX UI/backend activation
path, activate the cluster manually, then rerun playbook 34. Automation does
not attempt activation, deletion, recreation, or a control-plane restart.
`Deactivated` is also a terminal structured polling status, while only
`Running` is accepted as success. The playbook does not create or delete the
CDW Hive service principal or its keytab; the Private Cloud Data Warehouse
control plane owns `hive/<hostname>@<realm>` creation and key rotation.

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

CAI external-PKI variables are standalone Ansible controller paths:
`ecs_cai_tls_certificate_path`, `ecs_cai_tls_private_key_path`, and
`ecs_cai_tls_ca_bundle_path`. `ecs_cai_static_subdomain` defaults to `cai` and
must be a valid lowercase DNS label no longer than 15 characters.
`ecs_cai_tls_minimum_validity_seconds` defaults to one day.
AD and deployments without an in-inventory FreeIPA server must configure the
CA bundle even when reusing a pre-existing secret so trust can be verified.
CAI discovery lists the environment and selects the requested workbench by the
API field `instanceName`. The effective name is selected deterministically from
the bounded sequence `<ecs_cai_workspace_name>`, `-2`, `-3`, and so on (default
10 attempts, maximum name length 40). The default sequence is `cai-wb-1`,
`cai-wb-2`, `cai-wb-3`, and so on. `ecs_cai_workspace_name` remains an
override: a trailing number is incremented in place (`custom-7`, `custom-8`);
an override without a trailing number uses `custom`, `custom-2`, `custom-3`.
Existing workspaces are never renamed. Reruns first reuse a healthy or
provisioning workspace that authoritatively owns the configured endpoint
(including an older `-ml` name), then reuse the first real
active/provisioning workspace in that sequence. Failed, deleting, and reserved
names are skipped without deletion. A create-time `already exists` response
triggers a fresh authoritative list/describe lookup; a returned reusable object
is adopted, while an invisible or unusable reservation is recorded and the
next bounded workspace and endpoint pair is attempted (`name-2` with `cai-2`,
and so on). `ecs_cai_static_subdomain` remains the configured base label,
but an adopted workspace always derives the effective endpoint label from its
authoritative `instanceUrl`. For example, adopting `name-2` at
`https://cai.apps...` retains `cai`; automation never infers `cai-2` from the
workspace name. Endpoint versioning and matching trusted TLS apply only when a
new candidate must be created.
Final diagnostics and the portal catalog carry the effective workspace name,
current live status, and skipped unusable-name evidence. A reused healthy
workspace reports `Existing and running (green)`; a newly submitted workspace
reports `Created successfully (green)`.

Model Registry existence uses parsed `list-model-registries` JSON, matching
`serviceName` or `namespace` within the requested environment. A same-name
registry is accepted only in a known healthy terminal state and is reported as
`Existing (healthy)` without creating human credentials or submitting another
create request. New registries report `Created successfully`; unknown,
nonterminal, or failed states are surfaced instead of treated as success.

## Not automated (Labs reference gaps)

- FreeIPA wildcard TLS for CDE-specific domains; CAI `cml-tls-secret` is automated.
- Prometheus ingress patches on ECS masters (reference `ecs_masters` plays).
- CDE environment-role permissions for end users.
