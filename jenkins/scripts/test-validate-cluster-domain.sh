#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="$REPO_ROOT/scripts/lib/validate_cluster_domain.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

"$PY" --domain lab.example.com --quiet-warnings
"$PY" --domain cluster.home.arpa --quiet-warnings

if "$PY" --domain pvc.lab.local --quiet-warnings 2>/dev/null; then
  fail "expected pvc.lab.local to fail"
fi

if ! "$PY" --domain cldrsetup.local --quiet-warnings 2>/dev/null; then
  fail "expected grandfathered cldrsetup.local to pass (warn only)"
fi

if ANSIBLE_GROUP_VARS_YAML='ipaserver_domain: bad.internal' \
  "$REPO_ROOT/jenkins/scripts/validate-cluster-domain.sh" 2>/dev/null; then
  fail "expected user-set bad.internal to fail"
fi

if ANSIBLE_GROUP_VARS_YAML='' "$REPO_ROOT/jenkins/scripts/validate-cluster-domain.sh" >/dev/null; then
  echo "OK validate-cluster-domain tests"

else
  fail "empty ANSIBLE_GROUP_VARS should skip (--user-set-only)"
fi
