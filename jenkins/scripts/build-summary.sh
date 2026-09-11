#!/usr/bin/env bash
# Write deployment summary artifact for Jenkins email / archive.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$OUT_DIR"

cd "$REPO_ROOT"
if [[ -f "$REPO_ROOT/scripts/lib/load_tfvars.sh" ]]; then
  # shellcheck source=scripts/lib/load_tfvars.sh
  source "$REPO_ROOT/scripts/lib/load_tfvars.sh"
  set -a
  load_tfvars 2>/dev/null || true
  set +a
fi

SUMMARY="$OUT_DIR/build-summary.txt"
INVENTORY="$REPO_ROOT/ansible-playbooks/inventory.ini"

{
  echo "CDP On-Prem Automation — Build Summary"
  echo "======================================"
  echo "Timestamp:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Build:        ${JOB_NAME:-local} #${BUILD_NUMBER:-0}"
  echo "URL:          ${BUILD_URL:-n/a}"
  echo "Result:       ${BUILD_RESULT:-UNKNOWN}"
  echo "Action:       ${PIPELINE_ACTION:-${PIPELINE_STAGES:-${PIPELINE_MODE:-n/a}}}"
  echo "Environment:  ${ENVIRONMENT:-n/a}"
  echo "AWS Region:   ${AWS_REGION:-n/a}"
  echo "Owner:        ${OWNER:-n/a}"
  echo "Credentials:  ${CREDENTIALS_USER:-holautosa}"
  echo "VPC:            ${VPC_MODE:-USE_DEFAULT} (create_vpc=${CREATE_VPC:-false})"
  echo "Security grp:   ${SG_MODE:-USE_EXISTING} (create_new_sg=${CREATE_NEW_SG:-false}, name=${EXISTING_SG_NAME:-${SG_NAME:-n/a}})"
  echo "Key pair:       ${KEYPAIR_NAME:-n/a} (create=${CREATE_KEYPAIR:-false})"
  echo "Deploy Phase: ${DEPLOY_PHASE:-n/a}"
  echo "Dry Run:      ${DRY_RUN:-false}"
  echo "Terraform:    ${RUN_TERRAFORM:-false}"
  echo "Ansible:      ${RUN_ANSIBLE:-false}"
  echo ""
  echo "Instance groups (effective after Jenkins overrides):"
  echo "  cldr-mngr:      count=${CLDR_MNGR_COUNT:-?} type=${CLDR_MNGR_INSTANCE_TYPE:-?} vol=${CLDR_MNGR_VOLUME_SIZE:-?}GB"
  echo "  ipa-server:     count=${IPA_SERVER_COUNT:-?} type=${IPA_SERVER_INSTANCE_TYPE:-?}"
  echo "  base-master:    count=${PVCBASE_MASTER_COUNT:-?}"
  echo "  base-worker:    count=${PVCBASE_WORKER_COUNT:-?} type=${PVCBASE_WORKER_INSTANCE_TYPE:-?}"
  echo "  ecs-master:     count=${PVCECS_MASTER_COUNT:-?}"
  echo "  ecs-worker:     count=${PVCECS_WORKER_COUNT:-?} type=${PVCECS_WORKER_INSTANCE_TYPE:-?}"
  echo "  ami_id:         ${AMI_ID:-?}"
  echo ""
  if [[ -n "${ERROR_MESSAGE:-}" ]]; then
    echo "Error:"
    echo "${ERROR_MESSAGE}"
    echo ""
  fi
  if [[ -f "$INVENTORY" ]]; then
    echo "Inventory groups:"
    awk '/^\[/ { gsub(/[\[\]]/, "", $0); g=$0; c=0; next } /^[^#[:space:]]/ { c++ } END {}' "$INVENTORY" 2>/dev/null || true
    awk '
      /^\[/ { gsub(/[\[\]]/, "", $0); g=$0; next }
      /^[^#[:space:]]/ && g != "" { count[g]++ }
      END { for (g in count) printf "  %-20s %d host(s)\n", g, count[g] }
    ' "$INVENTORY" | sort
    echo ""
    echo "CM host (cldr-mngr):"
    awk '/^\[cldr-mngr\]/,/^\[/ { if ($0 !~ /^\[/ && $0 !~ /^#/) print "  " $0 }' "$INVENTORY" | head -3
  else
    echo "Inventory: not generated"
  fi
  echo ""
  echo "Artifacts directory: $OUT_DIR"
  ls -la "$OUT_DIR" 2>/dev/null || true
} > "$SUMMARY"

printf '%s\n' "$SUMMARY"
