#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RENDERER="$REPO_ROOT/jenkins/scripts/render-ansible-group-vars-override.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/input.yml" <<'YAML'
arbitrary_future_variable: accepted
cm_repo_username: from-yaml
nested_override:
  retries: 7
  enabled: true
YAML

ANSIBLE_GROUP_VARS_FILE="$TMP_DIR/input.yml" \
  python3 "$RENDERER" "$TMP_DIR/output.yml" >/dev/null

python3 - "$TMP_DIR/output.yml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    values = yaml.safe_load(stream)

assert values["arbitrary_future_variable"] == "accepted"
assert values["cm_repo_username"] == "from-yaml"
assert values["nested_override"] == {"retries": 7, "enabled": True}
PY

printf '%s\n' '- invalid' '- top-level-list' >"$TMP_DIR/invalid.yml"
if ANSIBLE_GROUP_VARS_FILE="$TMP_DIR/invalid.yml" \
  python3 "$RENDERER" --validate-only /dev/null >/dev/null 2>&1; then
  echo "FAIL: non-mapping YAML was accepted" >&2
  exit 1
fi

echo "OK: unrestricted Ansible group_vars overrides"
