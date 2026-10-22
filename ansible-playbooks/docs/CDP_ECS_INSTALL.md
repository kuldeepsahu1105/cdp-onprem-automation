# ECS (Experience Cluster) install

Playbook `33_setup_ecs_cluster.yml` provisions Cloudera Data Services on `ecs-masters` / `ecs-workers` after the CDH base cluster (`31_setup_base_cluster.yml`) and CM agents are in place.

The flow follows the phased pattern in [Cloudera Labs reference playbooks](https://github.com/cloudera-labs) (cluster shell → hosts → parcel → services → host templates → control plane → start). This repo targets **`cloudera.cluster` v4.4.0**, which has no `control_plane` or `host_template` modules (those appear in collection v5). Control plane installation uses `cloudera.cluster.cm_resource` (`installEmbeddedControlPlane`); host templates use CM REST via the same module.

## Prerequisites

| Requirement | Variable / group |
|-------------|------------------|
| Base cluster | `cdh_basecluster_name` |
| ECS nodes in inventory | `ecs-masters`, `ecs-workers` (`ecs_cluster_master_group`, `ecs_cluster_worker_group`) |
| Parcel repo | `ecs_parcel_repo_url` merged via `configure_cm_parcel_repo_api.yml` |
| CM API auth | `resolve_cm_cluster_module_endpoint.yml` (HTTPS when Auto-TLS) |

The ECS wildcard DNS record must resolve to the ECS master **private IP** from
the ECS nodes. Playbook `19_setup_wildcard.yml` prefers the inventory
`private_ip` and verifies `console-cdp.<ecs_app_domain>` after updating FreeIPA.
Playbook 33 repeats the lookup from the ECS master and fails before First Run if
the hostname resolves to a public address, preventing `helm-install-all` from
hanging on a self-connection through the public IP.

## Phased steps (new cluster)

1. **Cluster shell** — `cloudera.cluster.cluster` `state: present`, `type: EXPERIENCE_CLUSTER`, `cluster_version` from `ecs_parcel_version` or the pinned ECS repository manifest.
2. **Hosts** — `cloudera.cluster.host` `state: attached` for master and workers (FQDN = `cldr_hostname.cluster_domain`).
3. **Parcel** — `cloudera.cluster.parcel` `state: activated` for product `ECS`.
4. **Services** — `cloudera.cluster.service` + `service_config` for `docker` and `ecs` (credentials in a separate `service_config` task with `no_log`).
   Boolean CM parameters such as `external_registry_enabled` are sent and
   verified as lowercase strings because `cloudera.cluster` v4.4 otherwise
   serializes Python booleans as invalid `True`/`False` values.
5. **Host templates** — `common_tasks/ecs_apply_host_templates.yml`
   (`ECSMaster`, `ECSWorker`) through the v4-compatible CM API, applied with
   `startRoles=false`.
6. **Control plane submission/adoption** — `common_tasks/ecs_install_control_plane.yml` submits First Run or adopts its durable `/controlPlanes` record without blocking on completion.
7. **CoreDNS during First Run** — as soon as RKE2 and the CoreDNS ConfigMap exist, retain `/etc/resolv.conf` in its `forward` stanza, add `policy sequential` exactly as in the shared reference, and restart CoreDNS only when changed.
8. **First Run completion** — wait for the submitted CM command, or for an adopted installation to reach `STARTED`, only after CoreDNS is repaired.
9. **Start** — `cloudera.cluster.cluster` `state: started`.
10. **Operator CLI** — expose the RKE2 `kubectl` binary, copy a user-owned kubeconfig for `root` and the SSH user, install checksum-verified `k9s`, and verify that each user can list Kubernetes nodes.

An existing cluster that is missing required services or is not fully `STARTED`
re-enters the idempotent phased installer, allowing failed control-plane
installation to resume without deleting the ECS cluster.
When CM already has a matching `/controlPlanes` record, reruns adopt that
installation, repair CoreDNS while the existing First Run is active, and then
wait for completion instead of submitting a competing install or cluster-start
command.

## Key variables

| Variable | Purpose |
|----------|---------|
| `ecs_cluster_name` | CM cluster name (default `<deployment_name_prefix>-ecs-cluster`; `ecs-cluster` with an empty prefix) |
| `ecs_app_domain` | ECS `app_domain` / console DNS base (default `apps.<cluster_domain>`) |
| `ecs_pvc_ds_version` / `ecs_parcel_repo_url` | CDS private repo and parcel URL |
| `ecs_console_admin_password` | UMS bootstrap admin for embedded control plane (complexity rules enforced) |
| `ecs_control_plane_container_id` | Runtime container user ID written as `Container.Id` in `valuesYaml` (CM 7.13.2 default `1000001`) |
| `ecs_control_plane_install_poll_retries` / `ecs_control_plane_install_poll_delay` | Wait bound for the asynchronous CM First Run command (`240 × 15s`, one hour) |
| `ecs_cluster_cidr` / `ecs_service_cidr` | Kubernetes pod and service networks (`172.42.0.0/16` / `172.43.0.0/16`) |
| `ecs_docker_registry` / `ecs_image_basepath` | External Cloudera image registry and repository base path |
| `ecs_control_plane_embedded_db_storage_gb` / `ecs_control_plane_embedded_vault_storage_gb` | Embedded control-plane database and Vault storage (`200` / `20`) |
| `ecs_reconcile_coredns` | Enforce sequential `/etc/resolv.conf` forwarding in RKE2 CoreDNS during control-plane First Run |
| `ecs_cli_tools_enabled` | Configure `kubectl`, kubeconfig, and `k9s` on the ECS master for fresh installs and reruns |
| `ecs_cli_users` | Accounts receiving `~/.kube/config` (default `root` and `ansible_user`) |
| `ecs_k9s_version` / `ecs_k9s_checksums` | Pinned, checksum-verified k9s release and architecture checksums |
| `ecs_deploy_enabled` | `auto` \| `true` \| `false` |
| `ecs_deploy_on_arm64` | Default `false`; set true for Graviton ECS |

## Data services (CDE / CDW / CAI)

`34_setup_ecs_data_services.yml` runs after ECS when `ecs_data_services_deploy_enabled` is true. Reference playbooks use `cloudera.cloud.*` modules and Caddy on `reverse_proxy`; stubs live under `common_tasks/ecs_data_service_*.yml` for incremental alignment with Labs.

## Collection v5

For `control_plane` and `host_template` modules plus cm-client v57, see `docs/CLOUDERA_CLUSTER_V5_MIGRATION.md` (spike branch; not used in Jenkins today).
