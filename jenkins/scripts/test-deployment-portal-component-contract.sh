#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
portal_templates = root / "ansible-playbooks/roles/deployment_portal/templates"
index = (portal_templates / "deployment_portal_index.html.j2").read_text()
endpoints = (portal_templates / "deployment_portal_endpoints.j2").read_text()
base_urls = (
    portal_templates
    / "deployment_portal_base_cluster_portal_urls.j2"
).read_text()
sanitized_links = (
    portal_templates
    / "deployment_portal_sanitized_data_service_links.j2"
).read_text()
facts = (
    root
    / "ansible-playbooks/roles/deployment_portal/tasks/build_deployment_portal_facts.yml"
).read_text()
model_registry = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_model_registry.yml"
).read_text()
blackbox = (
    root
    / "ansible-playbooks/roles/deployment_portal/templates/monitoring_blackbox_probe_targets.j2"
).read_text()

for component in (
    "Cloudera Manager",
    "pgAdmin",
    "Grafana",
    "Prometheus",
    "Alertmanager",
    "cAdvisor",
    "FreeIPA",
    "ECS",
    "Deployment portal",
):
    assert component in index or component in endpoints, component

assert "ctx.data_services.links | default([])" in index
assert "ctx.ecs.links | default([])" in index
assert "deployment_portal_data_service_links" in sanitized_links
assert "deployment_portal_dynamic_links" in facts
assert "deployment_portal_dynamic_links: []" in facts
assert "deployment_portal_ecs_ds_links" in facts
assert "deployment_portal_sanitized_data_service_links" in facts
for add_on in (
    "HDFS NameNode UI",
    "Ozone Recon UI",
    "Ranger Admin",
    "Knox Gateway",
):
    assert add_on in base_urls, add_on
    assert add_on not in index, add_on
for service in ("cdw", "cde", "cai", "model_registry"):
    assert f"- key: {service}" in facts
    assert service in blackbox

assert "Update portal catalog URL for Model Registry" in model_registry
assert "'model_registry'" in model_registry
assert "ecs_model_registry_subdomain" in model_registry

print("Deployment portal component contract checks passed")
PY
