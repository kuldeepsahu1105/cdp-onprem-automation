# CDP base cluster service dependencies (7.3.x)

Authoritative matrix: [Service Dependencies in Cloudera Manager](https://docs.cloudera.com/cloudera-manager/7.13.2/cloudera-manager-installation/topics/cdpdc-service-dependencies.html).

`31_setup_base_cluster.yml` renders `templates/base_cluster_cluster_spec.j2` from `base_cluster_install_services` in `group_vars/all.yml`. Only set **service-level** config keys that exist for that service type in CM (invalid keys return HTTP 400).

## Required service-level links (this repo)

| Service | Config keys used in template |
|---------|------------------------------|
| HDFS | `zookeeper_service`, `core_connector` |
| YARN | `hdfs_service`, `zookeeper_service` |
| Tez | `yarn_service` only |
| Hive | `hdfs_service`, `zookeeper_service`, `mapreduce_yarn_service`; optional `ranger_service`, `hbase_service`, `atlas_service` |
| Hive on Tez | `hdfs_service`, `hms_connector`, `tez_service`, `mapreduce_yarn_service`, `zookeeper_service`; optional ranger/hbase/atlas |
| HBase | `hdfs_service`, `zookeeper_service` |
| Hue | `hdfs_service`; with Hive + Hive on Tez (CDP 7+): `hms_service: hive`, `hive_service: hive_on_tez`; optional hbase/impala/`solr_service`/atlas/zookeeper when those services enabled |
| Impala | `hdfs_service`, `hive_service`; optional `hbase_service` |
| Kafka | `zookeeper_service` |
| Atlas | `hdfs_service`, `kafka_service`; optional `hbase_service`, `solr_service`, `ranger_service` |
| **Ranger** | **`hdfs_service`**; **`solr_service`** when Solr is enabled (not `hive_service` / `kafka_service`) |
| Solr | `hdfs_service`, `zookeeper_service` — do **not** set `ranger_service` on the Solr instance used for Ranger audits (cyclic dependency) |
| Ozone | `hdfs_service` |

## Not on CDH 7.3.2 parcel (disabled by default)

- `ICEBERG`, `REPLICATION_MANAGER` — enable only on runtimes that expose those service types.

## Ranger + Solr

Ranger depends on **HDFS + Solr** for default audit storage/search. Default `group_vars/all.yml` sets `solr: true` with `ranger: true` (template sets `ranger.config.solr_service` and `hue.config.solr_service` when Solr is enabled). Set `solr: true` whenever `ranger: true`, or configure Ranger for Solr-only audits per [CFM/CDP install guidance](https://docs.cloudera.com/cfm/4.12.0/deployment/topics/cfm-install-cdp.html).

## Host templates (`base_cluster_cluster_spec.j2`)

In `host_templates.role_groups`, the `service` key must be the Cloudera Manager **service type** (`HDFS`, `YARN`, …), not the cluster service **name** (`hdfs`, `yarn`). `cloudera.cluster.cluster` resolves base role config groups with `ApiService.type == service`.

## ECS (playbook 33)

Experience cluster uses phased install; see `docs/CDP_ECS_INSTALL.md`.
