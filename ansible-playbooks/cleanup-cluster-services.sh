#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="all"
EXECUTE=false
INVENTORY="inventory.ini"

usage() {
  cat <<'EOF'
Usage:
  ./cleanup-cluster-services.sh [--scope base|ecs|all] [--inventory PATH]
  ./cleanup-cluster-services.sh [--scope base|ecs|all] [--inventory PATH] --execute

Without --execute, the playbook previews the selected hosts and paths.
Execution successfully stops and deletes the selected CM cluster registration,
then removes service config/data/log/runtime state while preserving:
  - Cloudera Manager server, agents, packages, and agent host UUIDs
  - /opt/cloudera/parcels and /opt/cloudera/csd
  - parcel caches and package repositories
  - PostgreSQL databases, roles, and contents

ECS scope is a destructive rebuild: parcel killall/uninstall helpers run and
configured ECS storage paths are removed only when they are not mounted.

Use 99_cleanup.yml for full E2E node teardown. Database schema objects are
removed only when that playbook removes Cloudera Manager.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || { echo "ERROR: --scope requires a value" >&2; exit 2; }
      SCOPE="$2"
      shift 2
      ;;
    --inventory)
      [[ $# -ge 2 ]] || { echo "ERROR: --inventory requires a path" >&2; exit 2; }
      INVENTORY="$2"
      shift 2
      ;;
    --execute)
      EXECUTE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SCOPE" in
  base|ecs|all) ;;
  *)
    echo "ERROR: --scope must be base, ecs, or all" >&2
    exit 2
    ;;
esac

args=(
  -i "$INVENTORY"
  98_cleanup_cluster_services.yml
  -e "cleanup_cluster_services_scope_input=$SCOPE"
  -e "cleanup_cluster_services_execute_input=$EXECUTE"
)

if [[ "$EXECUTE" == true ]]; then
  args+=(-e "cleanup_cluster_services_confirm_input=DELETE-CLUSTER-SERVICE-DATA")
fi

exec "$SCRIPT_DIR/run-playbook.sh" "${args[@]}"
