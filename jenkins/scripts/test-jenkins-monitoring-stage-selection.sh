#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${repo_root}/Jenkinsfile" <<'PY'
from pathlib import Path
import re
import sys

jenkinsfile = Path(sys.argv[1]).read_text()


def function_body(name: str) -> str:
    match = re.search(
        rf"def {re.escape(name)}\([^)]*\) \{{(?P<body>.*?)\n\}}",
        jenkinsfile,
        re.DOTALL,
    )
    assert match, f"missing Jenkins helper {name}"
    return match.group("body")


portal_body = function_body("portalDeployEnabled")
assert "DEPLOYMENT_PORTAL_ENABLED" in portal_body
assert "monitoringStackEnabled" not in portal_body

parse_body = function_body("parseSelectedStages")
assert "csv instanceof Collection" in parse_body
assert "csv instanceof Object[]" in parse_body
assert ".getClass().isArray()" not in parse_body

canonical_body = function_body("canonicalizePipelineStages")
assert "normalizePipelineStageToken" in canonical_body
assert "!unique.contains(normalized)" in canonical_body
assert "orderedPipelineStageIds().findAll" in canonical_body

implicit_body = function_body("addImplicitDeploymentStages")
assert "return canonicalizePipelineStages(stages)" in implicit_body
assert "PORTAL" not in implicit_body
assert "MONITORING" not in implicit_body

effective_body = function_body("effectivePipelineStages")
assert effective_body.count("canonicalizePipelineStages") >= 2
assert "addImplicitDeploymentStages(stages)" in effective_body
assert "CDH_BASE" not in jenkinsfile

should_run_body = function_body("shouldRunAnsibleStage")
assert "PIPELINE_STAGES_RESOLVED" in should_run_body
assert "applyResolvedPipelineStages()" in should_run_body

resolved_body = function_body("applyResolvedPipelineStages")
assert "resolvePipelineStages(params.PIPELINE_STAGES, env.VALIDATION_CHECKS)" in resolved_body
assert "env.SELECTED_ANSIBLE_STAGES = cfg.selectedAnsibleStages" in resolved_body
assert "env.PIPELINE_STAGES_RESOLVED = 'true'" in resolved_body

ordered_body = function_body("orderedAnsibleStageIds")
assert ordered_body.index("'PORTAL'") < ordered_body.index("'MONITORING'")
assert ordered_body.index("'MONITORING'") < ordered_body.index("'IDENTITY'")

monitoring_stage = re.search(
    r"stage\('Ansible 3 — Monitoring Stack'\).*?"
    r"shouldRunAnsibleStage\('MONITORING'\) && monitoringStackEnabled\(\)",
    jenkinsfile,
    re.DOTALL,
)
assert monitoring_stage
assert jenkinsfile.index("stage('Ansible 2 — Deployment Portal (bootstrap)')") < monitoring_stage.start()
assert monitoring_stage.end() < jenkinsfile.index("stage('Ansible 4 — Identity')")

pipeline_order = [
    "VALIDATE",
    "TERRAFORM",
    "PREREQS",
    "PORTAL",
    "MONITORING",
    "IDENTITY",
    "CM_INSTALL",
    "CM_TLS_KRB_LDAP",
    "CDH_INSTALL",
    "ECS_INSTALL",
    "ECS_POST_INSTALL_TASKS",
    "ECS_DATA_SERVICES",
    "STARTSTOP_AUTOMATION",
    "DESTROY_STACK",
]
aliases = {
    "CDH": "CDH_INSTALL",
    "ECS": "ECS_INSTALL",
    "ECS_POST_INSTALL": "ECS_POST_INSTALL_TASKS",
    "POST_INSTALL": "ECS_POST_INSTALL_TASKS",
    "DATA_SERVICES": "ECS_DATA_SERVICES",
    "DATASERVICES": "ECS_DATA_SERVICES",
    "CM_TLS": "CM_TLS_KRB_LDAP",
    "CM_TLS_KRB": "CM_TLS_KRB_LDAP",
    "TLS_KRB_LDAP": "CM_TLS_KRB_LDAP",
}


def effective(value):
    if isinstance(value, (list, tuple)):
        raw = []
        for item in value:
            raw.extend(str(item).split(","))
    else:
        raw = str(value).split(",")
    normalized = []
    for token in raw:
        token = token.strip().upper().replace("-", "_")
        token = aliases.get(token, token)
        if token and token not in normalized:
            normalized.append(token)
    result = [stage for stage in pipeline_order if stage in normalized]
    return [stage for stage in pipeline_order if stage in result]


assert effective("ECS_INSTALL,ECS_DATA_SERVICES") == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
assert effective([" ecs ", "DATA_SERVICES", "ecs-install", "dataservices"]) == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
assert effective("PORTAL,MONITORING,PORTAL") == ["PORTAL", "MONITORING"]
assert effective("PORTAL") == ["PORTAL"]
assert effective("MONITORING") == ["MONITORING"]
assert effective(
    "VALIDATE,TERRAFORM,PREREQS,PORTAL,MONITORING,IDENTITY,CM_INSTALL,"
    "CM_TLS_KRB_LDAP,CDH_INSTALL,ECS_INSTALL,ECS_POST_INSTALL_TASKS,"
    "ECS_DATA_SERVICES,ECS_INSTALL"
) == pipeline_order[:-2]
assert effective(effective("ECS_INSTALL,ECS_DATA_SERVICES")) == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
# Jenkins Restart from Stage skips the earlier Resolve Stages stage. Re-resolving
# the persisted build parameter must reproduce the same exact selection.
assert effective(" ECS_INSTALL, ECS_DATA_SERVICES ") == effective(
    ["ECS_INSTALL", "ECS_DATA_SERVICES"]
)

pvc_setup = (Path(sys.argv[1]).parent / "ansible-playbooks" / "pvc_setup.sh").read_text()
assert "_portal_actions_selected()" in pvc_setup
monitoring_phase = re.search(
    r"run_phase_monitoring\(\) \{(?P<body>.*?)\n\}",
    pvc_setup,
    re.DOTALL,
)
assert monitoring_phase
assert "run_playbook 32_setup_monitoring_stack.yml" in monitoring_phase.group("body")
assert "10_setup_deployment_portal.yml" not in monitoring_phase.group("body")
assert "35_refresh_deployment_portal.yml" not in monitoring_phase.group("body")
assert "_maybe_sync_deployment_portal_access" not in monitoring_phase.group("body")
assert "ecs_data_services_sync_portal_routes=false" in pvc_setup
assert "ecs_data_services_sync_portal_routes=true" in pvc_setup
assert "run_playbook 33_setup_ecs_cluster.yml" in pvc_setup
assert "run_playbook 34_setup_ecs_data_services.yml" in pvc_setup
assert "_run_ecs_post_install()" in pvc_setup
assert "_run_ecs_post_install() {\n  run_playbook 34_setup_ecs_post_install.yml\n  _maybe_sync_deployment_portal_access" in pvc_setup

jenkinsfile = Path(sys.argv[1]).read_text()
assert "JENKINS ANSIBLE PHASE START:" in jenkinsfile
assert "JENKINS ANSIBLE PHASE END:" in jenkinsfile
assert "phaseStatus = 'FAILED'" in jenkinsfile
assert "phaseStatus = 'SUCCESS'" in jenkinsfile
assert "} finally {" in jenkinsfile

data_services = (
    Path(sys.argv[1]).parent
    / "ansible-playbooks"
    / "roles"
    / "ecs"
    / "tasks"
    / "setup_data_services.yml"
).read_text()
assert data_services.count(
    "ecs_data_services_sync_portal_routes | default(true) | bool"
) >= 2

print("Jenkins phase selection and portal/monitoring gating checks passed")
PY
