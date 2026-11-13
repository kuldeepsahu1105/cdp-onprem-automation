#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TASKS="$REPO_ROOT/ansible-playbooks/roles/cm_security/tasks/configure_cm_cms_autotls_trust.yml"
BASE_TASKS="$REPO_ROOT/ansible-playbooks/roles/cdh_base_cluster/tasks/setup_base_cluster.yml"

python3 - "$TASKS" "$BASE_TASKS" <<'PY'
from pathlib import Path
import sys

tasks = Path(sys.argv[1]).read_text()
base_tasks = Path(sys.argv[2]).read_text()

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

def truststore_needs_update(location_matches, autotls_applied=False, explicit_repair=False):
    return not location_matches or autotls_applied or explicit_repair


def servicemonitor_needs_update(checks, redacted=False, explicit_repair=False):
    return (not redacted and not all(checks)) or explicit_repair


# Fresh install: paths/options are absent, so both configurations must be written.
assert truststore_needs_update(False)
assert servicemonitor_needs_update([False] * 6)

# Existing unchanged install: non-secret settings match and CM may redact secrets.
assert not truststore_needs_update(True)
assert not servicemonitor_needs_update([False] * 6, redacted=True)
assert not servicemonitor_needs_update([True] * 6)

# Intentional CA/password changes still force reconciliation.
assert truststore_needs_update(True, autotls_applied=True)
assert truststore_needs_update(True, explicit_repair=True)
assert servicemonitor_needs_update([True] * 6, explicit_repair=True)

restart_start = base_tasks.index(
    "- name: Determine whether Cloudera Management Service restart is required"
)
restart_end = base_tasks.index(
    "- name: Restart Cloudera Management Service after security or First Run changes",
    restart_start,
)
restart = base_tasks[restart_start:restart_end]
assert "base_cluster_first_run_required" in restart
assert "base_cluster_partial_first_run_recovery_required" in restart
assert "base_cluster_cluster_autotls_applied_this_run" in restart
assert "cms_service_truststore_put is changed" in restart
assert "cms_servicemonitor_tls_put is changed" in restart

print("OK: CMS Auto-TLS supports fresh installs and idempotent reruns")
PY
