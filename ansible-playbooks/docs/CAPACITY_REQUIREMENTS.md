# Capacity and Minimum Resource Requirements

This document summarizes the infrastructure sizing configured by this
repository and the runtime resource reservations observed in the deployed ECS
cluster on 2026-11-02. It is a deployment planning baseline, not a replacement
for Cloudera's workload-specific production sizing exercise.

## Key findings

- The checked-in `.tfvars.yaml` now defines seven `m6a.8xlarge` ECS workers
  (32 vCPU, 128 GiB each). The live cluster observation below predates that
  change and contains eight `r5a.4xlarge` workers.
- Kubernetes reports **16 allocatable vcores and about 124 GiB memory per ECS
  worker**. Eight workers therefore provide about **128 vcores and 994 GiB
  allocatable memory**, not 256 vcores.
- The observed YuniKorn guaranteed reservations for the CDW platform plus
  `hive-vw`, `impala-vw`, and `trino-vw` total **163 vcores and 1,175,727 M
  memory** before general Kubernetes and ECS platform overhead.
- All three `xsmall` Virtual Warehouses cannot run concurrently on the
  observed eight `r5a.4xlarge` workers. With the new `m6a.8xlarge` default,
  aggregate memory becomes the limiting resource: use at least **11 workers**
  for the platform plus Hive, Impala, and Trino with modest headroom.
- Hive plus Impala without Trino reserve about **118 vcores and 814,934 M
  memory**. Use at least **8 `m6a.8xlarge` workers** to leave practical
  headroom for system workloads and per-node bin packing.

## Configured infrastructure

AWS capacities below use the standard instance specifications for the types in
`.tfvars.yaml`. Disk is the configured gp3 root volume.

The instance-family cost comparison uses Linux Shared On-Demand pricing in
`ap-southeast-1` as the reference region. At the time of validation,
`m6a.large`, `m6a.4xlarge`, and `m6a.8xlarge` cost USD 0.108, 0.864, and
1.728 per hour respectively. Older `m5a` equivalents had the same prices;
newer `m6a` was selected. Although `t3a.large` was cheaper than
`m6a.large`, it was excluded for FreeIPA because its burstable CPU-credit
model is unsuitable for sustained DNS, LDAP, KDC, and CA service. Graviton
types were excluded because the repository defaults to an x86_64 AMI and ECS
on ARM64 is disabled unless explicitly enabled as experimental.
Pricing and capacity availability differ by region and Availability Zone.
Use the Jenkins instance-type parameters or tfvars to override `m6a` where it
is unavailable or another compatible x86_64 family is cheaper.

| Component | Count | Instance type | vCPU each | Memory each | Disk each | Aggregate |
|---|---:|---|---:|---:|---:|---|
| Cloudera Manager + PostgreSQL + CMS | 1 | `m6a.4xlarge` | 16 | 64 GiB | 300 GiB | 16 vCPU, 64 GiB, 300 GiB |
| FreeIPA | 1 | `m6a.large` | 2 | 8 GiB | 250 GiB | 2 vCPU, 8 GiB, 250 GiB |
| Base master | 1 | `m6a.4xlarge` | 16 | 64 GiB | 400 GiB | 16 vCPU, 64 GiB, 400 GiB |
| Base workers | 3 | `m6a.4xlarge` | 16 | 64 GiB | 400 GiB | 48 vCPU, 192 GiB, 1.2 TiB |
| ECS master | 1 | `m6a.8xlarge` | 32 | 128 GiB | 1.3 TiB | 32 vCPU, 128 GiB, 1.3 TiB |
| ECS workers, checked-in config | 7 | `m6a.8xlarge` | 32 | 128 GiB | 1.3 TiB | 224 vCPU, 896 GiB, 9.1 TiB |
| ECS workers, live observation before default change | 8 | `r5a.4xlarge` | 16 allocatable | about 124 GiB allocatable | 1.3 TiB configured | 128 vCPU, about 994 GiB allocatable, 10.4 TiB raw |

The live worker count differs from `.tfvars.yaml`, so Jenkins or another
deployment override supplied the eighth worker.

## Infrastructure minimums

These minimums are appropriate for this repository's combined lab/integration
service set. Production deployments require workload, retention, concurrency,
and high-availability calculations.

| Component | Minimum CPU | Minimum memory | Minimum disk | Repository/current recommendation | Notes |
|---|---:|---:|---:|---|---|
| FreeIPA | 2 vCPU | 8 GiB | 100 GiB | 2 vCPU, 8 GiB, 250 GiB | This is the stable non-burstable lab minimum. DNS, LDAP, KDC, CA, and Directory Server share one host; increase memory for larger directories or heavier authentication load. |
| Cloudera Manager server | 8 vCPU | 32 GiB | 100 GiB | 16 vCPU, 64 GiB, shared 300 GiB | Also runs CMS roles and, by default, PostgreSQL. |
| PostgreSQL for CM and Base services | 4 vCPU | 16 GiB | 150 GiB | Shared CM host, 300 GiB total | Hosts CM, Reports Manager, Ranger, Hive, Hue, Oozie/Knox and related service databases. Use a separate DB host for production or high retention. |
| Cloudera Management Service | 4 vCPU within CM host | 12 GiB within CM host | 50 GiB logs/indexes | Service Monitor heap alone is configured to 6 GiB | Host Monitor, Service Monitor, Event Server, Alert Publisher, and Reports Manager grow with host and metric count. |
| Base master | 12 vCPU | 48 GiB | 300 GiB | 16 vCPU, 64 GiB, 400 GiB | Runs master roles for HDFS, YARN, Ozone, Hive, HBase, Impala, Kafka, Atlas, Ranger, Solr, Knox, Hue, and ZooKeeper. |
| Base worker | 12 vCPU each | 48 GiB each | 300 GiB each | 3 x 16 vCPU, 64 GiB, 400 GiB | Three workers are the practical minimum for distributed service placement. More are needed for real HDFS/Ozone capacity and replication. |
| ECS master | 16 vCPU | 64 GiB | 500 GiB | 32 vCPU, 128 GiB, 1.3 TiB | RKE2 control plane, etcd, registry/control-plane services, images, and operational logs. |
| ECS worker | 32 vCPU each | 128 GiB each | 1 TiB each | `m6a.8xlarge`, 1.3 TiB | Selected as a lowest-priced compatible x86_64 32-vCPU/128-GiB shape in `ap-southeast-1` at the time of validation; `m5a.8xlarge` had the same On-Demand price. CDW templates remain memory-heavy. |

## Base cluster service footprint

The repository enables nearly the full Base service set. Exact per-role heaps
are primarily selected by Cloudera Manager templates and parcel defaults, so
the infrastructure host totals above are the authoritative configured sizing.

| Base service group | Main resource pressure | Minimum placement in this setup | Storage considerations |
|---|---|---|---|
| ZooKeeper | Low CPU, latency-sensitive memory/disk | Master plus distributed roles as generated by CM | Fast, reliable local transaction logs |
| HDFS | DataNode disk and NameNode heap | Master roles plus all Base workers | Capacity must include replication and free-space reserve |
| Ozone | DataNode disk, SCM/OM metadata | Master roles plus Base workers | Capacity must include replication; avoid filling root volumes |
| YARN/Tez/Spark | Worker CPU and memory | NodeManager on Base workers | Repository currently caps each NodeManager at 4 vcores and 4 GiB, suitable only for smoke/integration workloads |
| Hive/Hive on Tez | Metastore DB, HS2 heap, YARN capacity | Master/service roles plus YARN workers | Warehouse data is on HDFS/Ozone; PostgreSQL stores metadata |
| Impala | Worker memory and CPU | Coordinators/catalog/statestore plus executors on workers | Leave substantial memory outside YARN for Impala |
| HBase | RegionServer memory and data disk | Base workers | HDFS/Ozone capacity and ZooKeeper latency matter |
| Kafka | Disk throughput and page cache | Base workers | Size for retention, replication, and peak ingress |
| Ranger/Atlas/Solr | JVM heap, PostgreSQL, index disk | Primarily master/service hosts | Solr indexes and audit retention can grow quickly |
| Hue/Knox | Moderate CPU/memory, PostgreSQL | Master/service host | Hue and Knox metadata use PostgreSQL |

## ECS platform storage

| Item | Configured value | Planning guidance |
|---|---:|---|
| ECS worker root volume | 1.3 TiB per worker | Reserve space for container images, logs, `/mnt/docker`, `/ecs/local-storage`, and `/ecs/longhorn-storage` |
| Longhorn replication | `1` | Lowest capacity overhead but no replica redundancy; production should evaluate higher replication and additional disk |
| Embedded control-plane PostgreSQL | 200 GiB | Stored within ECS platform storage |
| Embedded Vault | 20 GiB | Stored within ECS platform storage |
| NFS over-provisioning | `800` | Logical provisioning can exceed physical storage; monitor actual usage and disk pressure |

## Data Service resource requirements

### CDW platform and Virtual Warehouses

The following values come from the live `yunikorn-configs` ConfigMap generated
for environment `cldr`. `M` values are reported exactly as YuniKorn emits them.

| CDW component/queue | Guaranteed vcores | Guaranteed memory | Maximum vcores | Maximum memory |
|---|---:|---:|---:|---:|
| CDW log router | 9 | 20,480 M | 9 | 20,480 M |
| CDW monitoring | 1 | 4,096 M | Not explicitly capped | Not explicitly capped |
| Database Catalog / warehouse | 12 | 35,085 M | 13 | 43,277 M |
| Hive `xsmall` (`compute-hive-vw`) | 33 | 271,232 M | 138 | 1,242,192 M |
| Impala `xsmall` (`impala-impala-vw`) | 63 | 484,041 M | 177 | 1,422,233 M |
| Trino `xsmall` (`trino-trino-vw`) | 45 | 360,793 M | 45 | 360,793 M |
| **CDW + Hive + Impala** | **118** | **814,934 M** | Dynamic | Dynamic |
| **CDW + Hive + Impala + Trino** | **163** | **1,175,727 M** | Dynamic | Dynamic |

The following primary-container requests were captured from the live Hive
`xsmall` namespace after the warehouse became healthy. Kubernetes schedules
from requests, so these values are more useful for placement planning than
observed CPU utilization. Init containers and injected sidecars are not listed
here; their overhead and queue headroom explain the difference between the
primary-container total and the 33-vcore/271,232-M YuniKorn guarantee.

| Hive `xsmall` component | Replicas | CPU request each | Memory request each | CPU subtotal | Memory subtotal |
|---|---:|---:|---:|---:|---:|
| HiveServer2 | 1 | 4 vcores | 16,384 M | 4 | 16,384 M |
| Hue backend | 1 | 1 vcore | 8,192 M | 1 | 8,192 M |
| Hue frontend | 1 | 100 millicores | 512 Mi | 0.1 | 512 Mi |
| Query coordinator | 2 | 1 vcore | 4,096 M | 2 | 8,192 M |
| Query executor | 2 | 12 vcores | 116,736 M | 24 | 233,472 M |
| Standalone compute operator | 1 | 200 millicores | 2,048 M | 0.2 | 2,048 M |
| Usage monitor | 1 | 50 millicores | 128 Mi | 0.05 | 128 Mi |
| Hue database-create job | 1 job | No request declared | No request declared | 0 | 0 |
| **Primary-container total** |  |  |  | **31.35 vcores** | **268,288 M + 640 Mi** |

The two Hive query executors also declare one `local-path` cache PVC each.
The live manifests report the requested storage quantity as literal `1`; both
claims remained Pending while their executor pods were unscheduled. Confirm
the intended unit in the generated CDW template before using that value for
disk-capacity planning.

The following regular-container requests were captured from the live Impala
`xsmall` namespace with two executors after the warehouse became healthy.
Unlike the Hive table, this table includes generated support sidecars because
the live KCM failure occurred in `autoscaler-metrics-shipper`, not in an
Impala daemon. This is the complete steady-state `spec.containers` scheduling
request for the observed warehouse; init containers and queue headroom remain
additional considerations.

| Impala `xsmall` component | Replicas | CPU request each | Memory request each | CPU subtotal | Memory subtotal |
|---|---:|---:|---:|---:|---:|
| Catalog daemon | 1 | 400 millicores | 8,192 M | 0.4 | 8,192 M |
| Catalog support sidecars | 2 | 50 millicores | 64 Mi | 0.1 | 128 Mi |
| Coordinator | 1 | 400 millicores | 24,576 M | 0.4 | 24,576 M |
| Coordinator support sidecars | 4 | 50 millicores | 64 Mi | 0.2 | 256 Mi |
| Hue backend | 1 | 500 millicores | 8,192 M | 0.5 | 8,192 M |
| Hue coordinator-health sidecar | 1 | 50 millicores | 128 Mi | 0.05 | 128 Mi |
| Hue frontend | 1 | 100 millicores | 512 Mi | 0.1 | 512 Mi |
| Impala autoscaler | 1 | 100 millicores | 1,024 M | 0.1 | 1,024 M |
| Autoscaler web-UI metrics | 1 | 500 millicores | 768 Mi | 0.5 | 768 Mi |
| Autoscaler metrics shipper | 1 | 50 millicores | 64 Mi | 0.05 | 64 Mi |
| Impala executor | 2 | 3 vcores | 24,576 M | 6 | 49,152 M |
| Executor support sidecars | 4 | 50 millicores | 64 Mi | 0.2 | 256 Mi |
| StateStore daemon | 1 | 100 millicores | 512 M | 0.1 | 512 M |
| StateStore support sidecar | 1 | 50 millicores | 64 Mi | 0.05 | 64 Mi |
| Hue database-create job | 1 job | No request declared | No request declared | 0 | 0 |
| **Regular-container total** |  |  |  | **8.75 vcores** | **91,648 M + 2,176 Mi (about 87.48 GiB)** |

The observed Impala YuniKorn guarantee is much larger than the steady-state
pod request total because it reserves warehouse growth and autoscaling
headroom. Size the worker pool against the queue guarantee when several
warehouses coexist, not only against the initial two-executor pod footprint.

The following regular-container requests were captured from the live Trino
`xsmall` namespace with two workers after the warehouse became healthy.
Support sidecars are included for consistency with the Impala measurement.

| Trino `xsmall` component | Replicas | CPU request each | Memory request each | CPU subtotal | Memory subtotal |
|---|---:|---:|---:|---:|---:|
| Hue backend | 1 | 500 millicores | 8,192 M | 0.5 | 8,192 M |
| Hue frontend | 1 | 100 millicores | 512 Mi | 0.1 | 512 Mi |
| Trino autoscaler | 1 | 1 vcore | 512 M | 1 | 512 M |
| Trino coordinator | 1 | 4 vcores | 24,576 M | 4 | 24,576 M |
| Coordinator JVM-dump sidecar | 1 | 50 millicores | 64 Mi | 0.05 | 64 Mi |
| Trino worker | 2 | 4 vcores | 24,576 M | 8 | 49,152 M |
| Worker JVM-dump sidecar | 2 | 50 millicores | 64 Mi | 0.1 | 128 Mi |
| Hue database-create job | 1 job | No request declared | No request declared | 0 | 0 |
| **Regular-container total** |  |  |  | **13.75 vcores** | **82,432 M + 704 Mi (about 77.46 GiB)** |

As with Impala, the 45-vcore/360,793-M YuniKorn guarantee is intentionally
larger than the initial two-worker pod request total. It represents queue and
scaling capacity, so use the guarantee—not only the initial footprint—when
planning to keep Trino active beside other warehouses.

Recommended ECS worker baselines using the new `m6a.8xlarge` worker shape:

| Enabled CDW workload | Theoretical minimum | Practical minimum |
|---|---:|---:|
| Database Catalog + one Hive `xsmall` | 3 workers by raw memory | **4 workers** |
| Database Catalog + Hive + Impala `xsmall` | 7 workers by raw memory | **8 workers** |
| Database Catalog + Hive + Impala + Trino `xsmall` | 10 workers by raw memory | **11 workers** |

The practical values include modest headroom for RKE2, Istio, monitoring,
registry, logging, DaemonSets, pod anti-affinity, and per-node bin packing.
They do not include high query concurrency or autoscaling toward the large
YuniKorn maximums.

### CDE

| Component | Configured request/quota | Disk |
|---|---:|---|
| CDE service | 40 vcores, 64 GiB memory | Uses ECS/Kubernetes storage plus Base/Ozone data storage |

Each additional CDE service or virtual cluster needs separate workload
capacity beyond the CDW totals.

### CAI / CML

| Component | Configured workspace quota | Disk |
|---|---:|---|
| CAI workspace | 50 vcores, 46 GiB memory, 0 GPU | Uses ECS persistent storage; project and model data growth must be planned separately |

GPU workloads require GPU workers, drivers, device plugins, and a nonzero GPU
quota; none are configured by default.

### Model Registry

The repository does not define a fixed CPU/memory quota for Model Registry.
It uses ECS workload capacity and Base Ozone S3 credentials. Reserve capacity
in addition to CDW/CDE/CAI and size object storage for model artifacts,
versions, and retention.

## Capacity checks

### Generate a live Markdown report

Run the standalone report script from any node or workstation whose current
`kubectl` context can read the ECS cluster:

```bash
cd ansible-playbooks
./report_ecs_capacity.sh --output ecs-capacity-$(date -u +%Y%m%dT%H%M%SZ).md
```

By default, the report includes:

- node capacity and allocatable resources;
- primary-container CPU and memory request totals for every namespace;
- all Pending pods and their scheduler messages;
- detailed primary/init-container requests and limits for discovered Data
  Service namespaces;
- PVC requested capacity, storage class, binding state, and volume;
- the live YuniKorn queue configuration.

Limit detailed output to one or more namespaces when capturing a specific
Virtual Warehouse:

```bash
./report_ecs_capacity.sh \
  --namespace compute-hive-vw \
  --output hive-xsmall-capacity.md

./report_ecs_capacity.sh \
  --namespace impala-impala-vw \
  --namespace trino-trino-vw \
  --output sql-warehouses-capacity.md
```

Use `--all-details` to include every namespace, or `--no-yunikorn` when access
to the YuniKorn ConfigMap is unavailable. The script requires `kubectl` and
`jq` and does not modify the cluster.

The static tables in this document are the checked-in planning baseline. To
refresh them after changing instance types, worker counts, warehouse sizes, or
CDP Runtime versions:

1. Create only one Virtual Warehouse type at a time.
2. Wait for its namespace and generated controllers to exist.
3. Apply the temporary FILE-cache verification patch below if the workload
   otherwise fails with `No KCM server found`.
4. Generate a namespace-scoped live report.
5. Record the primary/init-container and PVC values in the matching static
   component table before deleting that warehouse and testing the next type.

This isolates each `xsmall` template and prevents another warehouse from
distorting Pending-pod and scheduler-capacity observations.

### Temporary KCM verification patches

These commands are for live diagnosis only. Generated CDW controllers can be
reconciled back to their service configuration, so a direct Kubernetes patch
is not the durable automation boundary. Persist `KRB5CCNAME` through the CDW
Database Catalog or Virtual Warehouse service configuration after the manual
verification succeeds.

For Hive, wait for the generated StatefulSet, set a FILE cache on HiveServer2,
recreate its pod, and watch readiness:

```bash
until kubectl -n compute-hive-vw get statefulset hiveserver2 >/dev/null 2>&1; do
  sleep 5
done

kubectl -n compute-hive-vw set env statefulset/hiveserver2 \
  --containers=hiveserver2 \
  KRB5CCNAME=FILE:/tmp/krb5cc_hiveserver2

kubectl -n compute-hive-vw get statefulset hiveserver2 \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="hiveserver2")].env[?(@.name=="KRB5CCNAME")].value}{"\n"}'

kubectl -n compute-hive-vw delete pod hiveserver2-0 --ignore-not-found=true
kubectl -n compute-hive-vw get pod hiveserver2-0 -w
```

Successful Kerberos initialization contains:

```text
Using default cache: /tmp/krb5cc_hiveserver2
Authenticated to Kerberos v5
Ticket cache: FILE:/tmp/krb5cc_hiveserver2
```

Confirm it after the pod starts:

```bash
kubectl -n compute-hive-vw logs hiveserver2-0 -c hiveserver2 --tail=120 |
  grep -E 'Using default cache|Authenticated to Kerberos|Ticket cache|No KCM|kinit'
```

HiveServer2 was the container that failed in the observed Hive deployment.
For complete Hive, Impala, or Trino verification, patch every generated
container that mounts the keytab directory because credential-using support
containers can fail independently. The live Impala xsmall verification, for
example, found the KCM failure in `autoscaler-metrics-shipper`, not in an
Impala daemon. Each pod has an independent filesystem, so using the same cache
path does not share credential contents between pods.

Define this temporary helper on the ECS master:

```bash
patch_cdw_keytab_containers() {
  namespace=$1
  ccache=$2
  kubectl -n "$namespace" get statefulset,deployment -o json |
    jq -r '
      .items[] as $workload
      | $workload.spec.template.spec.containers[]
      | select(any(.volumeMounts[]?;
          ((.mountPath // "") | contains("/etc/security/keytabs"))))
      | "\($workload.kind | ascii_downcase) \($workload.metadata.name) \(.name)"
    ' |
    while read -r kind workload container; do
      kubectl -n "$namespace" set env "$kind/$workload" \
        --containers="$container" KRB5CCNAME="$ccache"
    done
}
```

Use it for each isolated warehouse:

```bash
patch_cdw_keytab_containers compute-hive-vw FILE:/tmp/krb5cc_hive
kubectl -n compute-hive-vw get pods -w

patch_cdw_keytab_containers impala-impala-vw FILE:/tmp/krb5cc_impala
kubectl -n impala-impala-vw get pods -w

patch_cdw_keytab_containers trino-trino-vw FILE:/tmp/krb5cc_trino
kubectl -n trino-trino-vw get pods -w
```

Do not delete CDW-generated namespaces directly. Delete Virtual Warehouses
through the CDW API or console so their control-plane state remains
consistent.

### Direct inspection commands

Run these commands on the ECS master before enabling an additional Data
Service:

```bash
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,TAINTS:.spec.taints'
kubectl top nodes
kubectl get pods -A --field-selector=status.phase=Pending -o wide
kubectl -n yunikorn get configmap yunikorn-configs -o yaml
```

For a pending workload, inspect scheduler events:

```bash
kubectl -n <namespace> describe pod <pod> | sed -n '/Events:/,$p'
```

Capture primary-container requests and limits for a warehouse namespace:

```bash
kubectl -n <namespace> get pods \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name,CPU_REQUESTS:.spec.containers[*].resources.requests.cpu,MEM_REQUESTS:.spec.containers[*].resources.requests.memory,EPHEMERAL_REQUESTS:.spec.containers[*].resources.requests.ephemeral-storage,CPU_LIMITS:.spec.containers[*].resources.limits.cpu,MEM_LIMITS:.spec.containers[*].resources.limits.memory,EPHEMERAL_LIMITS:.spec.containers[*].resources.limits.ephemeral-storage'
```

Capture persistent-storage requests:

```bash
kubectl -n <namespace> get pvc \
  -o custom-columns='PVC:.metadata.name,REQUESTED:.spec.resources.requests.storage,CLASS:.spec.storageClassName,STATUS:.status.phase,VOLUME:.spec.volumeName'
```

`Task ... is pending for the requested resources become available` from
YuniKorn means the request cannot currently fit within allocatable node
resources and queue placement. Low live CPU utilization does not mean the pod
can be scheduled: Kubernetes and YuniKorn schedule from declared requests and
queue reservations, not current utilization.

## Disk planning notes

- Keep at least 20% free space on operating-system, container-runtime, and
  database volumes.
- PostgreSQL sizing must include database growth, WAL, temporary query space,
  backups, and maintenance operations.
- Base HDFS/Ozone/Kafka disk must be calculated from retained data multiplied
  by replication, plus compaction and operational headroom.
- ECS worker disk must include pulled CDP images, container writable layers,
  logs, Longhorn/LSO data, and failed workload remnants.
- The configured Longhorn replication factor of one improves usable capacity
  but does not protect against loss of a worker volume.
