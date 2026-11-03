#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
caddy = (
    root / "ansible-playbooks/templates/deployment_portal_Caddyfile.j2"
).read_text()
monitoring_env = (
    root / "ansible-playbooks/templates/monitoring_docker-compose.env.j2"
).read_text()
verify = (
    root / "ansible-playbooks/common_tasks/verify_deployment_portal_monitoring.yml"
).read_text()

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
