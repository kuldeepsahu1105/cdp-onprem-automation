#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="inventory.ini"
EXECUTE=false

usage() {
  cat <<'EOF'
Usage:
  ./rebuild-base-cluster.sh [--inventory PATH]
  ./rebuild-base-cluster.sh [--inventory PATH] --execute

Without --execute, previews the destructive base-only cleanup.

With --execute:
  1. Deletes only the CM base-cluster registration.
  2. Removes base service state while preserving CM, CMS, FreeIPA, ECS, and parcels.
  3. Resets Hive, Hue, Ranger, and Knox schemas while preserving databases/roles.
  4. Runs 31_setup_base_cluster.yml to recreate and start the base cluster.
  5. Verifies/enables CM Auto-TLS and cluster Kerberos, then restarts CMS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory)
      [[ $# -ge 2 ]] || { echo "ERROR: --inventory requires a value" >&2; exit 2; }
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

cleanup_args=(
  --scope base
  --inventory "$INVENTORY"
  --reset-base-databases
)

if [[ "$EXECUTE" != true ]]; then
  "$SCRIPT_DIR/cleanup-cluster-services.sh" "${cleanup_args[@]}"
  printf '\nPreview only. Re-run with --execute to clean and recreate the base cluster.\n'
  exit 0
fi

"$SCRIPT_DIR/cleanup-cluster-services.sh" "${cleanup_args[@]}" --execute
exec "$SCRIPT_DIR/run-playbook.sh" \
  -i "$INVENTORY" \
  31_setup_base_cluster.yml
