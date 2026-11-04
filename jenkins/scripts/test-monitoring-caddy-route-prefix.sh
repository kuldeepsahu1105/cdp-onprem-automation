#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
role_templates = root / "ansible-playbooks/roles/deployment_portal/templates"
compat_templates = root / "ansible-playbooks/templates"
caddy = (role_templates / "deployment_portal_Caddyfile.j2").read_text()
compat_caddy = (compat_templates / "deployment_portal_Caddyfile.j2").read_text()
monitoring_env = (role_templates / "monitoring_docker-compose.env.j2").read_text()
compat_monitoring_env = (
    compat_templates / "monitoring_docker-compose.env.j2"
).read_text()
verify = (
    root
    / "ansible-playbooks/roles/deployment_portal/tasks"
    / "verify_deployment_portal_monitoring.yml"
).read_text()
compat_verify = (
    root / "ansible-playbooks/common_tasks/verify_deployment_portal_monitoring.yml"
).read_text()

assert caddy == compat_caddy
assert monitoring_env == compat_monitoring_env
assert "name: deployment_portal" in compat_verify
assert "tasks_from: verify_deployment_portal_monitoring" in compat_verify
assert (
    "{% set _monitoring_path_handler = 'handle_path' "
    "if (caddy_vhost_enabled | default(false) | bool) else 'handle' %}"
) in caddy
for service in ("grafana", "prometheus", "alertmanager"):
    assert f"{{{{ _monitoring_path_handler }}}} /{service}/*" in caddy

assert (
    "PROMETHEUS_WEB_ROUTE_PREFIX={{ ('/' if "
    "(caddy_vhost_enabled | default(false) | bool) else '/prometheus')"
) in monitoring_env
assert (
    "ALERTMANAGER_WEB_ROUTE_PREFIX={{ ('/' if "
    "(caddy_vhost_enabled | default(false) | bool) else '/alertmanager')"
) in monitoring_env
assert '"{{ _monitoring_local_base }}/prometheus/-/healthy"' in verify
assert '"{{ _monitoring_local_base }}/grafana/login"' in verify

print("monitoring Caddy route-prefix checks passed")
PY
