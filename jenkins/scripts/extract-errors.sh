#!/usr/bin/env bash
# Extract error lines from Jenkins stage logs for email / build description.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/jenkins/artifacts}"
OUT_FILE="${OUT_FILE:-$LOG_DIR/error-summary.txt}"

mkdir -p "$LOG_DIR"
: > "$OUT_FILE"

append_matches() {
  local label="$1" file="$2"
  [[ -f "$file" ]] || return 0
  local hits
  hits="$(grep -Ein 'fatal:|error:|ERROR:|FAILED!|Error:|non-zero return code|Required tool not found|❌|ui_err' "$file" 2>/dev/null | tail -40 || true)"
  if [[ -n "$hits" ]]; then
    {
      echo "=== $label ($file) ==="
      echo "$hits"
      echo ""
    } >> "$OUT_FILE"
  fi
}

append_matches "Terraform" "$LOG_DIR/terraform-${BUILD_NUMBER:-local}.log"
for f in "$LOG_DIR"/ansible-${BUILD_NUMBER:-local}-phase*.log; do
  [[ -f "$f" ]] && append_matches "Ansible" "$f"
done
append_matches "Validation" "$LOG_DIR/validate-${BUILD_NUMBER:-local}.log"

if [[ ! -s "$OUT_FILE" ]]; then
  echo "No structured errors found in stage logs. Check full Jenkins console output." > "$OUT_FILE"
fi

head -80 "$OUT_FILE"
