#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import json
import re
import sys

from jinja2 import Environment, FileSystemLoader, StrictUndefined
import yaml

root = Path(sys.argv[1])
templates = root / "ansible-playbooks" / "templates"
env = Environment(
    loader=FileSystemLoader(str(templates)),
    undefined=StrictUndefined,
    keep_trailing_newline=True,
)
env.filters["bool"] = lambda value: str(value).lower() in {"1", "true", "yes", "on"}
env.filters["regex_replace"] = lambda value, pattern, replacement: re.sub(pattern, replacement, str(value))
env.filters["regex_search"] = lambda value, pattern: re.search(pattern, str(value)).group(0) if re.search(pattern, str(value)) else None
env.filters["to_json"] = json.dumps


def render(name, **context):
    return env.get_template(name).render(**context)


def caddy_urls(ip, base, mode="custom_base"):
    return yaml.safe_load(
        render(
            "caddy_vhost_urls.j2",
            caddy_vhost_ip_for_urls=ip,
            deployment_portal_ops_public_ip=ip,
            deployment_portal_ops_private_ip="10.0.0.10",
            caddy_vhost_public_base=base,
            deployment_portal_http_port=81,
            deployment_portal_ipa_https_port=9443,
            deployment_portal_ipa_https_enabled=True,
            caddy_vhost_dns_mode=mode,
            caddy_vhost_service_names={
                "portal": "portal",
                "pgadmin": "pgadmin",
                "grafana": "grafana",
                "prometheus": "prometheus",
                "alertmanager": "alertmanager",
                "cadvisor": "cadvisor",
                "ipa": "ipa",
            },
        )
    )


sample = caddy_urls("47.128.73.19", "pvc.cloudera-labs.com")
assert sample["ipa"]["url"] == "https://ipa.47-128-73-19.pvc.cloudera-labs.com:9443"
assert sample["ipa"]["url"] + "/ipa/modern-ui/" == (
    "https://ipa.47-128-73-19.pvc.cloudera-labs.com:9443/ipa/modern-ui/"
)

alternate = caddy_urls("10.24.8.15", "lab.example.com")
assert alternate["ipa"]["url"] == "https://ipa.10-24-8-15.lab.example.com:9443"

ecs_template = "deployment_portal_ecs_cm_links.j2"
public_links = yaml.safe_load(
    render(
        ecs_template,
        deployment_portal_cm_ui_base_url="https://18.140.181.97:7183/",
        deployment_portal_ecs_service_id="1546338949",
    )
)
assert public_links == [
    {
        "name": "ECS Management / Workloads",
        "url": "https://18.140.181.97:7183/cmf/services/1546338949/ecsWebUI/#/workloads?namespace=all",
        "description": "ECS workloads across all namespaces",
    },
    {
        "name": "Longhorn UI",
        "url": "https://18.140.181.97:7183/cmf/services/1546338949/longhorn/",
        "description": "ECS persistent storage management",
    },
]
private_links = yaml.safe_load(
    render(
        ecs_template,
        deployment_portal_cm_ui_base_url="https://cldr-mngr.corp.example:7183",
        deployment_portal_ecs_service_id="42",
    )
)
assert private_links[0]["url"].startswith("https://cldr-mngr.corp.example:7183/cmf/services/42/")

configured_links = [
    {"name": "Operator runbook", "url": "https://ops.example/runbook", "description": "Keep me"},
    {"name": "ECS Management / Workloads", "url": public_links[0]["url"]},
    {"name": "Longhorn UI", "url": "https://old.example:7183/cmf/services/999/longhorn/"},
    {"name": "Operator runbook duplicate", "url": "https://ops.example/runbook"},
]
data_service_links = [
    {"name": "CDW", "url": "https://dw.example"},
    {"name": "CDW duplicate", "url": "https://dw.example"},
]
sanitized = yaml.safe_load(
    render(
        "deployment_portal_sanitized_data_service_links.j2",
        deployment_portal_data_service_links=configured_links,
        deployment_portal_ecs_ds_links=data_service_links,
    )
)
assert sanitized == [
    {"name": "Operator runbook", "url": "https://ops.example/runbook", "description": "Keep me"},
    {"name": "CDW", "url": "https://dw.example"},
]
rerun = yaml.safe_load(
    render(
        "deployment_portal_sanitized_data_service_links.j2",
        deployment_portal_data_service_links=sanitized,
        deployment_portal_ecs_ds_links=[],
    )
)
assert rerun == sanitized

facts = (root / "ansible-playbooks/common_tasks/build_deployment_portal_facts.yml").read_text()
index = (templates / "deployment_portal_index.html.j2").read_text()
base_urls = (templates / "deployment_portal_base_cluster_portal_urls.j2").read_text()
ipa_httpd = (templates / "ipa_httpd_disable_browser_krb.conf.j2").read_text()
ipa_proxy = (templates / "deployment_portal_Caddyfile_ipa_proxy.inc.j2").read_text()
discovery = (
    root / "ansible-playbooks/common_tasks/discover_deployment_portal_ecs_cm_links.yml"
).read_text()

assert "deployment_portal_dynamic_links: []" in facts
assert "deployment_portal_dynamic_links | default([])" not in facts
assert "ctx.ecs.links | default([])" in index
assert '<span class="tile-label">Cloudera Manager</span>' in index
assert '<span class="tile-label">ECS</span>' in index
for unwanted in ("Ranger Admin", "Ozone Recon UI", "HDFS NameNode UI", "Knox Gateway"):
    assert unwanted in base_urls
    assert unwanted not in index

assert 'SetEnvIf Request_URI "^/ipa(/|$)" gssapi-no-negotiate=1' in ipa_httpd
assert re.search(r"(?m)^<Location\s+/ipa>", ipa_httpd) is None
assert "header -WWW-Authenticate" not in ipa_proxy
assert "@ipa_session path /ipa/session /ipa/session/*" in ipa_proxy
assert "header_up Host {{ deployment_portal_ipa_fqdn }}" in ipa_proxy
assert "tls_server_name {{ deployment_portal_ipa_fqdn }}" in ipa_proxy
assert 'header_down Set-Cookie "{{ deployment_portal_ipa_fqdn }}" "{{ _ipa_caddy_vhost_host }}"' in ipa_proxy
assert "services/ecs?view=full" in discovery
assert "serviceId" in discovery and "serviceUrl" in discovery
assert "Follow ECS service UI redirect" in discovery
assert "cm_external_url" in discovery
assert "deployment_portal_cm_public_ip" in discovery
assert "deployment_portal_cm_fqdn" in discovery
assert "namespace=all" in (templates / ecs_template).read_text()

print("Deployment portal quicklink and FreeIPA browser-login regressions passed")
PY
