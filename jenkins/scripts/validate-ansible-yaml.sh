#!/usr/bin/env bash
# Parse-check Ansible task YAML (catches invalid when: list items before ansible-playbook runs).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ANSIBLE_DIR="${ANSIBLE_DIR:-$REPO_ROOT/ansible-playbooks}"

ANSIBLE_DIR="$ANSIBLE_DIR" python3 - <<'PY'
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("validate-ansible-yaml: python3 yaml module required", file=sys.stderr)
    sys.exit(1)

root = Path(os.environ["ANSIBLE_DIR"])
paths = sorted(
    set(root.glob("common_tasks/**/*.yml"))
    | set(root.glob("common_tasks/*.yml"))
    | set(root.glob("[0-9]*.yml"))
)
errors = []
for path in sorted(paths):
    try:
        with path.open() as fh:
            yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        errors.append(f"{path}: {exc}")

if errors:
    for line in errors:
        print(f"[validate-ansible-yaml] ERROR: {line}", file=sys.stderr)
    sys.exit(1)

print(f"[validate-ansible-yaml] OK: {len(paths)} Ansible YAML file(s) parsed")
PY
