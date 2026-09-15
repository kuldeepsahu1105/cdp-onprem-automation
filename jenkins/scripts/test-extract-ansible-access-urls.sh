#!/usr/bin/env bash
# Quick regression for CDP_ACCESS_URLS extraction from Ansible JSON debug output.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${REPO_ROOT}/jenkins/scripts/extract-ansible-access-urls.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/phase.log" <<'EOF'
TASK [Print CDP access URLs for pipeline log and email collectors] ***
ok: [localhost] => {
    "msg": "========== CDP_ACCESS_URLS_BEGIN ==========\nDeployment portal access profile: public (aws)\n  Portal:    http://10.0.0.1:81/\n========== CDP_ACCESS_URLS_END =========="
}
EOF

out="$(python3 "$PY" "$TMP/phase.log")"
grep -q 'CDP_ACCESS_URLS_BEGIN' <<<"$out"
grep -q 'http://10.0.0.1:81/' <<<"$out"
grep -qv '\\n' <<<"$out"
grep -qv '"msg"' <<<"$out"

printf 'test-extract-ansible-access-urls: ok\n'
