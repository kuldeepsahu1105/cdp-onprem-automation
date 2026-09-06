#!/usr/bin/env bash
# Write deployment summary artifact for Jenkins email / archive.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/jenkins/artifacts}"
mkdir -p "$OUT_DIR"

SUMMARY="$OUT_DIR/build-summary.txt"
INVENTORY="$REPO_ROOT/ansible-playbooks/inventory.ini"

{
  echo "CDP On-Prem Automation — Build Summary"
  echo "======================================"
  echo "Timestamp:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Build:        ${JOB_NAME:-local} #${BUILD_NUMBER:-0}"
  echo "URL:          ${BUILD_URL:-n/a}"
  echo "Result:       ${BUILD_RESULT:-UNKNOWN}"
  echo "Pipeline:     ${PIPELINE_MODE:-n/a}"
  echo "Environment:  ${ENVIRONMENT:-n/a}"
  echo "AWS Region:   ${AWS_REGION:-n/a}"
  echo "Owner:        ${OWNER:-n/a}"
  echo "Deploy Phase: ${DEPLOY_PHASE:-n/a}"
  echo "Dry Run:      ${DRY_RUN:-false}"
  echo "Terraform:    ${RUN_TERRAFORM:-false}"
  echo "Ansible:      ${RUN_ANSIBLE:-false}"
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
