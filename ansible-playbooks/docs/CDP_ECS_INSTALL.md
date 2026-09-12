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

## Phased steps (new cluster)

1. **Cluster shell** — `cloudera.cluster.cluster` `state: present`, `type: EXPERIENCE_CLUSTER`, `cluster_version` from `ecs_parcel_version` or CM discovery.
2. **Hosts** — `cloudera.cluster.host` `state: attached` for master and workers (FQDN = `cldr_hostname.cluster_domain`).
3. **Parcel** — `cloudera.cluster.parcel` `state: activated` for product `ECS`.
4. **Services** — `cloudera.cluster.service` + `service_config` for `docker` and `ecs` (credentials in a separate `service_config` task with `no_log`).
5. **Host templates** — `common_tasks/ecs_apply_host_templates.yml` (`ecs_master`, `ecs_workers`).
6. **Control plane** — `common_tasks/ecs_install_control_plane.yml` with `valuesYaml` from `templates/ecs_control_plane_values.yaml.j2`.
7. **Start** — `cloudera.cluster.cluster` `state: started`.

If the cluster already exists (`GET` returns 200), only **start** runs, then console wait and optional IAM access-key provisioning.

## Key variables

| Variable | Purpose |
|----------|---------|
| `ecs_cluster_name` | CM cluster name (default `ECS-Cluster`) |
| `ecs_app_domain` | ECS `app_domain` / console DNS base (default `apps.<cluster_domain>`) |
| `ecs_pvc_ds_version` / `ecs_parcel_repo_url` | CDS private repo and parcel URL |
| `ecs_console_admin_password` | UMS bootstrap admin for embedded control plane (complexity rules enforced) |
| `ecs_deploy_enabled` | `auto` \| `true` \| `false` |
| `ecs_deploy_on_arm64` | Default `false`; set true for Graviton ECS |

## Data services (CDE / CDW / CAI)

`34_setup_ecs_data_services.yml` runs after ECS when `ecs_data_services_deploy_enabled` is true. Reference playbooks use `cloudera.cloud.*` modules and Caddy on `reverse_proxy`; stubs live under `common_tasks/ecs_data_service_*.yml` for incremental alignment with Labs.

## Collection v5

For `control_plane` and `host_template` modules plus cm-client v57, see `docs/CLOUDERA_CLUSTER_V5_MIGRATION.md` (spike branch; not used in Jenkins today).
