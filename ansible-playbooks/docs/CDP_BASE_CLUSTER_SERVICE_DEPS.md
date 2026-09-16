# CDP base cluster service dependencies (7.3.x)

Authoritative matrix: [Service Dependencies in Cloudera Manager](https://docs.cloudera.com/cloudera-manager/7.13.2/cloudera-manager-installation/topics/cdpdc-service-dependencies.html).

`31_setup_base_cluster.yml` renders `templates/base_cluster_cluster_spec.j2` from `base_cluster_install_services` in `group_vars/all.yml`. Only set **service-level** config keys that exist for that service type in CM (invalid keys return HTTP 400).

## Required service-level links (this repo)

| Service | Config keys used in template |
|---------|------------------------------|
| Core Settings | no required service reference; `GATEWAY` distributes shared client configuration |
| HDFS | `zookeeper_service`, `core_connector` |
| YARN | `hdfs_service`, `zookeeper_service`; optional `ranger_service` |
| Tez | `yarn_service` only |
| Spark 3 on YARN | `yarn_service`; roles `SPARK3_YARN_HISTORY_SERVER` and `GATEWAY` |
| Hive | `hdfs_service`, `zookeeper_service`, `mapreduce_yarn_service`; PostgreSQL metastore host, port, name, user, and password; optional `ranger_service`, `hbase_service`, `atlas_service` |
| Hive on Tez | `hdfs_service`, `hms_connector`, `tez_service`, `mapreduce_yarn_service`, `zookeeper_service`; optional ranger/hbase/atlas |
| HBase | `hdfs_service`, `zookeeper_service` |
| Hue | `hdfs_service`; on CDP 7+ with Hive + Hive on Tez use `hms_service: hive` and `hive_service: hive_on_tez`; optional hbase/impala/solr/atlas/zookeeper when those services enabled |
| Impala | `hdfs_service`, `hive_service` (HMS); optional `hbase_service`, `ranger_service`, `atlas_service` |
| Kafka | `zookeeper_service`; optional `hdfs_service`, `ranger_service` |
| Atlas | `hdfs_service`, `kafka_service`; optional `hbase_service`, `solr_service`, `ranger_service` |
| **Ranger** | **`hdfs_service`**; PostgreSQL connection and initial Admin/Keyadmin/Tagsync/Usersync passwords; **`solr_service`** when Solr is enabled (not `hive_service` / `kafka_service`) |
| Solr | `hdfs_service`, `zookeeper_service` — do **not** set `ranger_service` on the Solr instance used for Ranger audits (cyclic dependency) |
| NiFi | `hdfs_service`, `zookeeper_service`; optional `kafka_service` |
| NiFi Registry | no required service reference; CM type `NIFIREGISTRY`, roles `NIFI_REGISTRY_SERVER`, optional `GATEWAY` |
| Data Visualization | no required service reference; roles `DATAVIZ_WEBSERVER`, `DATAVIZ_REVERSE_PROXY` |
| Phoenix | `hbase_service`; role `PHOENIX_QUERY_SERVER` |
| Ozone | `ozone.service.id`, primordial SCM node; baseline roles `OZONE_MANAGER`, `STORAGE_CONTAINER_MANAGER`, `OZONE_DATANODE`, `OZONE_RECON`, `S3_GATEWAY` |
| Knox | PostgreSQL connection; `KNOX_GATEWAY.gateway_master_secret` |

## Not installed by default (intentional)

- **Oozie** — not in `base_cluster_install_services`; Hue `oozie_service` is omitted unless you add an Oozie service to the template.
- **REPLICATION_MANAGER** — disabled by default; not on the CDH 7.3.2 parcel. Enable only when the runtime exposes that service type.

## Iceberg

CDP Runtime 7.3.x provides Iceberg through Hive, Impala, and Spark rather than a
standalone `ICEBERG` CM service. The `iceberg` toggle therefore validates those
engine dependencies and does not render a service or role.

## Ranger + Solr

Ranger depends on **HDFS + Solr** for default audit storage/search. Default `group_vars/all.yml` sets `solr: true` with `ranger: true`. Set `solr: true` whenever `ranger: true`, or configure Ranger for Solr-only audits per [CFM/CDP install guidance](https://docs.cloudera.com/cfm/4.12.0/deployment/topics/cfm-install-cdp.html).

## Host templates (`base_cluster_cluster_spec.j2`)

In `host_templates.role_groups`, the `service` key must be the Cloudera Manager **service type** (`HDFS`, `YARN`, …), not the cluster service **name** (`hdfs`, `yarn`). `cloudera.cluster.cluster` resolves base role config groups with `ApiService.type == service`.

## ECS (playbook 33)

Experience cluster uses phased install; see `docs/CDP_ECS_INSTALL.md`.
