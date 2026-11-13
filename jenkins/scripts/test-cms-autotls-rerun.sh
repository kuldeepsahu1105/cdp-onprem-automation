#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TASKS="$REPO_ROOT/ansible-playbooks/roles/cm_security/tasks/configure_cm_cms_autotls_trust.yml"

python3 - "$TASKS" <<'PY'
from pathlib import Path
import sys

tasks = Path(sys.argv[1]).read_text()

drift_start = tasks.index("- name: CMS — detect drift in MGMT TLS client truststore settings")
drift_end = tasks.index("- name: CMS — detect obsolete service-level client keystore safety valve", drift_start)
drift = tasks[drift_start:drift_end]

assert "ssl_client_truststore_location" in drift
assert "selectattr('name', 'equalto', 'ssl_client_truststore_password')" not in drift
assert "autotls_applied_this_run" in drift
assert "cm_cms_update_autotls_truststore_password" in drift

opts_start = tasks.index("- name: CMS — build Service Monitor Auto-TLS JVM options")
opts_end = tasks.index("- name: CMS — classify redacted Service Monitor Java options", opts_start)
opts = tasks[opts_start:opts_end]
assert "cms_servicemonitor_existing_java_opts_item.get(" in opts
assert "'value'," in opts
assert "cms_servicemonitor_existing_java_opts_item.get('default', '')" in opts

print("OK: CMS Auto-TLS reruns preserve redacted secrets without repeated writes")
PY
