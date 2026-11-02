#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "cluster-info")
    exit 0
    ;;
  "config current-context")
    printf 'fixture-context\n'
    ;;
  "config view --minify -o jsonpath={.clusters[0].cluster.server}")
    printf 'https://fixture.example:6443'
    ;;
  "get nodes -o json")
    cat <<'JSON'
{"items":[{"metadata":{"name":"worker-1","labels":{"node-role.kubernetes.io/worker":""}},"status":{"capacity":{"cpu":"32","memory":"128Gi"},"allocatable":{"cpu":"31","memory":"124Gi","ephemeral-storage":"1200Gi"}}}]}
JSON
    ;;
  "get namespaces -o json")
    cat <<'JSON'
{"items":[{"metadata":{"name":"compute-hive-vw"}}]}
JSON
    ;;
  "get pods --all-namespaces -o json")
    cat <<'JSON'
{"items":[
  {"metadata":{"namespace":"compute-hive-vw","name":"hiveserver2-0"},"spec":{"schedulerName":"yunikorn","nodeName":"worker-1","containers":[{"name":"hiveserver2","resources":{"requests":{"cpu":"4","memory":"16384M"},"limits":{"memory":"16384M"}}}],"initContainers":[{"name":"init-cacerts","resources":{"requests":{"cpu":"10m","memory":"16Mi"}}}]},"status":{"phase":"Running"}},
  {"metadata":{"namespace":"compute-hive-vw","name":"query-executor-0-0"},"spec":{"schedulerName":"yunikorn","containers":[{"name":"query-executor","resources":{"requests":{"cpu":"12","memory":"116736M"},"limits":{"memory":"116736M"}}}]},"status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","message":"requested resources become available"}]}}
]}
JSON
    ;;
  "get pvc --all-namespaces -o json")
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"compute-hive-vw","name":"query-executor-0-0-cache-volume"},"spec":{"resources":{"requests":{"storage":"1"}},"storageClassName":"local-path"},"status":{"phase":"Pending"}}]}
JSON
    ;;
  "-n yunikorn get configmap yunikorn-configs -o json")
    cat <<'JSON'
{"data":{"queues.yaml":"partitions:\n  - name: default\n    queues:\n      - name: compute-hive-vw\n        resources:\n          guaranteed:\n            vcore: 33\n            memory: 271232M"}}
JSON
    ;;
  *)
    printf 'Unexpected kubectl arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp_dir/kubectl"

report="$tmp_dir/report.md"
PATH="$tmp_dir:$PATH" \
  "$repo_root/ansible-playbooks/report_ecs_capacity.sh" \
  --namespace compute-hive-vw \
  --output "$report"

grep -Fq '# ECS live capacity report' "$report"
grep -Fq '| worker-1 | worker | 32 | 31 | 128Gi | 124Gi | 1200Gi |' "$report"
grep -Fq '| compute-hive-vw | 2 | 1 | 1 | 16.000' "$report"
grep -Fq '| hiveserver2-0 | Running | primary | hiveserver2 | 4 | 16384M |' "$report"
grep -Fq '| hiveserver2-0 | Running | init | init-cacerts | 10m | 16Mi |' "$report"
grep -Fq '| query-executor-0-0-cache-volume | 1 | local-path | Pending | - |' "$report"
grep -Fq 'requested resources become available' "$report"
grep -Fq 'vcore: 33' "$report"

for readme in \
  "$repo_root/README.md" \
  "$repo_root/READme.adoc" \
  "$repo_root/ansible-playbooks/README.md"; do
  grep -Fq 'CAPACITY_REQUIREMENTS.md' "$readme"
  grep -Fq 'report_ecs_capacity.sh' "$readme"
  grep -Fq -- '--output /tmp/ecs-capacity.md' "$readme"
done

echo "ECS capacity report test passed"
