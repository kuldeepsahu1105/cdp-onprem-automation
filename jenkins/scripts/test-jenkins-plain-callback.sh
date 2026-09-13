#!/usr/bin/env bash
# Unit checks for jenkins_plain ok-host summarization (no Ansible run required).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PLUGIN="$REPO_ROOT/ansible-playbooks/callback_plugins/jenkins_plain.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 - <<'PY' "$PLUGIN"
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("jenkins_plain", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

assert mod.format_ok_summary([]) is None
assert mod.format_ok_summary(["a"]) == "  ok: [a]"
assert mod.format_ok_summary(["a", "b"]) == "  ok: 2 hosts — a, b"
long = [f"h{i}" for i in range(10)]
line = mod.format_ok_summary(long)
assert line.startswith("  ok: 10 hosts — h0, h1, h2, h3,")
assert "(+6 more)" in line
print("OK: format_ok_summary")
PY

echo "OK: jenkins_plain callback helpers"
