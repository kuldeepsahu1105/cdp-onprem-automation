#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Generate a Markdown ECS/Kubernetes capacity report from the current kubectl context.

Usage:
  ./report_ecs_capacity.sh [options]

Options:
  -n, --namespace NAME   Include detailed pod/container and PVC data for NAME.
                         May be repeated. When omitted, Data Service namespaces
                         are discovered from common CDW/CDE/CAI name prefixes.
  -o, --output FILE     Write the report to FILE instead of stdout.
      --all-details     Include detailed pod/container and PVC data for every
                         namespace that currently has a pod.
      --no-yunikorn     Omit the YuniKorn queue configuration section.
  -h, --help            Show this help.

Requirements:
  kubectl, jq, and permission to read nodes, namespaces, pods, PVCs, and the
  yunikorn/yunikorn-configs ConfigMap.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required but was not found"
}

markdown_cell() {
  local value="${1:-}"
  value="${value//$'\n'/<br>}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

namespaces=()
output_file=""
all_details=false
include_yunikorn=true

while (($#)); do
  case "$1" in
    -n|--namespace)
      (($# >= 2)) || fail "$1 requires a namespace"
      namespaces+=("$2")
      shift 2
      ;;
    -o|--output)
      (($# >= 2)) || fail "$1 requires a file path"
      output_file="$2"
      shift 2
      ;;
    --all-details)
      all_details=true
      shift
      ;;
    --no-yunikorn)
      include_yunikorn=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_command kubectl
require_command jq
kubectl cluster-info >/dev/null 2>&1 || fail "kubectl cannot reach the current cluster"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

kubectl get nodes -o json >"$tmp_dir/nodes.json"
kubectl get namespaces -o json >"$tmp_dir/namespaces.json"
kubectl get pods --all-namespaces -o json >"$tmp_dir/pods.json"
kubectl get pvc --all-namespaces -o json >"$tmp_dir/pvcs.json"

if $all_details; then
  while IFS= read -r namespace; do
    [[ -n "$namespace" ]] && namespaces+=("$namespace")
  done < <(jq -r '.items[].metadata.namespace' "$tmp_dir/pods.json" | sort -u)
elif ((${#namespaces[@]} == 0)); then
  while IFS= read -r namespace; do
    [[ -n "$namespace" ]] && namespaces+=("$namespace")
  done < <(
    jq -r '.items[].metadata.namespace' "$tmp_dir/pods.json" |
      sort -u |
      grep -E '^(compute-|impala-|trino-|warehouse-|cdw-|cde-|dex-|cml-|cai-|ml-|model-registry|monitoring)' ||
      true
  )
fi

for namespace in "${namespaces[@]}"; do
  jq -e --arg namespace "$namespace" \
    '.items[] | select(.metadata.name == $namespace)' \
    "$tmp_dir/namespaces.json" >/dev/null ||
    fail "namespace does not exist: $namespace"
done

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  exec >"$output_file"
fi

context="$(kubectl config current-context 2>/dev/null || printf 'unknown')"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat <<EOF
# ECS live capacity report

- Generated: \`$generated_at\`
- Kubectl context: \`$(markdown_cell "$context")\`
- API server: \`$(markdown_cell "${server:-unknown}")\`

## Node capacity

| Node | Roles | Capacity CPU | Allocatable CPU | Capacity memory | Allocatable memory | Allocatable ephemeral storage |
|---|---|---:|---:|---:|---:|---:|
EOF

jq -r '
  .items[]
  | [
      .metadata.name,
      (
        [.metadata.labels
          | to_entries[]
          | select(.key | startswith("node-role.kubernetes.io/"))
          | (.key | split("/")[-1])
        ] | if length == 0 then "worker" else join(",") end
      ),
      (.status.capacity.cpu // "0"),
      (.status.allocatable.cpu // "0"),
      (.status.capacity.memory // "0"),
      (.status.allocatable.memory // "0"),
      (.status.allocatable["ephemeral-storage"] // "0")
    ]
  | @tsv
' "$tmp_dir/nodes.json" |
  while IFS=$'\t' read -r name roles capacity_cpu allocatable_cpu capacity_memory allocatable_memory ephemeral; do
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$(markdown_cell "$name")" \
      "$(markdown_cell "$roles")" \
      "$(markdown_cell "$capacity_cpu")" \
      "$(markdown_cell "$allocatable_cpu")" \
      "$(markdown_cell "$capacity_memory")" \
      "$(markdown_cell "$allocatable_memory")" \
      "$(markdown_cell "$ephemeral")"
  done

cat <<'EOF'

## Declared primary-container requests by namespace

These totals sum regular entries in `spec.containers`. Init-container requests,
injected sidecars, PodOverhead, scheduler queue guarantees, topology rules, and
DaemonSet/system reservations must be considered separately.

| Namespace | Pods | Running | Pending | CPU requests (cores) | Memory requests (GiB) |
|---|---:|---:|---:|---:|---:|
EOF

jq -r '
  def cpu_cores:
    if . == null or . == "" then 0
    elif test("n$") then rtrimstr("n") | tonumber / 1000000000
    elif test("u$") then rtrimstr("u") | tonumber / 1000000
    elif test("m$") then rtrimstr("m") | tonumber / 1000
    else tonumber
    end;
  def memory_bytes:
    if . == null or . == "" then 0
    elif test("Ki$") then rtrimstr("Ki") | tonumber * 1024
    elif test("Mi$") then rtrimstr("Mi") | tonumber * 1048576
    elif test("Gi$") then rtrimstr("Gi") | tonumber * 1073741824
    elif test("Ti$") then rtrimstr("Ti") | tonumber * 1099511627776
    elif test("K$") then rtrimstr("K") | tonumber * 1000
    elif test("M$") then rtrimstr("M") | tonumber * 1000000
    elif test("G$") then rtrimstr("G") | tonumber * 1000000000
    elif test("T$") then rtrimstr("T") | tonumber * 1000000000000
    else tonumber
    end;
  .items
  | group_by(.metadata.namespace)[]
  | [
      .[0].metadata.namespace,
      length,
      (map(select(.status.phase == "Running")) | length),
      (map(select(.status.phase == "Pending")) | length),
      (
        map(
          [.spec.containers[]? | (.resources.requests.cpu // "0" | cpu_cores)]
          | add // 0
        ) | add // 0
      ),
      (
        (
          map(
            [.spec.containers[]? | (.resources.requests.memory // "0" | memory_bytes)]
            | add // 0
          ) | add // 0
        ) / 1073741824
      )
    ]
  | @tsv
' "$tmp_dir/pods.json" |
  sort |
  while IFS=$'\t' read -r namespace pods running pending cpu memory; do
    printf '| %s | %s | %s | %s | %.3f | %.3f |\n' \
      "$(markdown_cell "$namespace")" "$pods" "$running" "$pending" "$cpu" "$memory"
  done

cat <<'EOF'

## Pending pods

| Namespace | Pod | Scheduler | Node | Scheduling message |
|---|---|---|---|---|
EOF

pending_count="$(
  jq '[.items[] | select(.status.phase == "Pending")] | length' "$tmp_dir/pods.json"
)"
if [[ "$pending_count" == "0" ]]; then
  printf '| - | None | - | - | - |\n'
else
  jq -r '
    .items[]
    | select(.status.phase == "Pending")
    | [
        .metadata.namespace,
        .metadata.name,
        (.spec.schedulerName // "default-scheduler"),
        (.spec.nodeName // "unassigned"),
        (
          [
            .status.conditions[]?
            | select(.type == "PodScheduled" and .status == "False")
            | .message
          ][0] // "-"
        )
      ]
    | @tsv
  ' "$tmp_dir/pods.json" |
    while IFS=$'\t' read -r namespace pod scheduler node message; do
      printf '| %s | %s | %s | %s | %s |\n' \
        "$(markdown_cell "$namespace")" \
        "$(markdown_cell "$pod")" \
        "$(markdown_cell "$scheduler")" \
        "$(markdown_cell "$node")" \
        "$(markdown_cell "$message")"
    done
fi

for namespace in "${namespaces[@]}"; do
  cat <<EOF

## Namespace: \`$(markdown_cell "$namespace")\`

### Primary and init container resources

| Pod | Phase | Container class | Container | CPU request | Memory request | Ephemeral request | CPU limit | Memory limit | Ephemeral limit |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
EOF

  namespace_rows="$(
    jq --arg namespace "$namespace" '
      [.items[] | select(.metadata.namespace == $namespace)] | length
    ' "$tmp_dir/pods.json"
  )"
  if [[ "$namespace_rows" == "0" ]]; then
    printf '| - | No pods | - | - | - | - | - | - | - | - |\n'
  else
    jq -r --arg namespace "$namespace" '
      .items[]
      | select(.metadata.namespace == $namespace)
      | .metadata.name as $pod
      | .status.phase as $phase
      | (
          (.spec.containers[]? | ["primary", .]),
          (.spec.initContainers[]? | ["init", .])
        )
      | .[0] as $class
      | .[1]
      | [
          $pod,
          $phase,
          $class,
          .name,
          (.resources.requests.cpu // "0"),
          (.resources.requests.memory // "0"),
          (.resources.requests["ephemeral-storage"] // "0"),
          (.resources.limits.cpu // "0"),
          (.resources.limits.memory // "0"),
          (.resources.limits["ephemeral-storage"] // "0")
        ]
      | @tsv
    ' "$tmp_dir/pods.json" |
      while IFS=$'\t' read -r pod phase class container cpu_request memory_request ephemeral_request cpu_limit memory_limit ephemeral_limit; do
        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
          "$(markdown_cell "$pod")" \
          "$(markdown_cell "$phase")" \
          "$(markdown_cell "$class")" \
          "$(markdown_cell "$container")" \
          "$(markdown_cell "$cpu_request")" \
          "$(markdown_cell "$memory_request")" \
          "$(markdown_cell "$ephemeral_request")" \
          "$(markdown_cell "$cpu_limit")" \
          "$(markdown_cell "$memory_limit")" \
          "$(markdown_cell "$ephemeral_limit")"
      done
  fi

  cat <<'EOF'

### Persistent volume claims

| PVC | Requested storage | Storage class | Phase | Volume |
|---|---:|---|---|---|
EOF

  pvc_count="$(
    jq --arg namespace "$namespace" '
      [.items[] | select(.metadata.namespace == $namespace)] | length
    ' "$tmp_dir/pvcs.json"
  )"
  if [[ "$pvc_count" == "0" ]]; then
    printf '| None | - | - | - | - |\n'
  else
    jq -r --arg namespace "$namespace" '
      .items[]
      | select(.metadata.namespace == $namespace)
      | [
          .metadata.name,
          (.spec.resources.requests.storage // "0"),
          (.spec.storageClassName // "-"),
          (.status.phase // "-"),
          (.spec.volumeName // "-")
        ]
      | @tsv
    ' "$tmp_dir/pvcs.json" |
      while IFS=$'\t' read -r pvc storage storage_class phase volume; do
        printf '| %s | %s | %s | %s | %s |\n' \
          "$(markdown_cell "$pvc")" \
          "$(markdown_cell "$storage")" \
          "$(markdown_cell "$storage_class")" \
          "$(markdown_cell "$phase")" \
          "$(markdown_cell "$volume")"
      done
  fi
done

if $include_yunikorn; then
  cat <<'EOF'

## YuniKorn queue configuration

The live queue configuration is included verbatim because queue guarantees and
maximums can exceed the currently instantiated pod requests.

EOF
  if kubectl -n yunikorn get configmap yunikorn-configs -o json >"$tmp_dir/yunikorn.json" 2>/dev/null; then
    jq -r '
      .data
      | to_entries[]
      | select(.value | test("partitions:|queues:|resources:"))
      | "### `" + .key + "`\n\n```yaml\n" + .value + "\n```\n"
    ' "$tmp_dir/yunikorn.json"
  else
    printf 'The `yunikorn/yunikorn-configs` ConfigMap was not readable.\n'
  fi
fi

cat <<'EOF'

## Interpretation notes

- Kubernetes and YuniKorn schedule declared requests and queue resources, not
  current CPU utilization.
- A low `kubectl top` value does not prove that another pod can fit.
- Review per-node fit, pod anti-affinity, taints, storage binding, and queue
  guarantees before concluding that aggregate cluster capacity is sufficient.
- Keep operational headroom for RKE2, Istio, logging, monitoring, image pulls,
  DaemonSets, and workload autoscaling.
EOF

if [[ -n "$output_file" ]]; then
  printf 'Wrote ECS capacity report to %s\n' "$output_file" >&2
fi
