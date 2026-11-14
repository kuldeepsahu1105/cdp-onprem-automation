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


parse_body = function_body("parseSelectedStages")
assert "csv instanceof Collection" in parse_body
assert "csv instanceof Object[]" in parse_body
assert ".getClass().isArray()" not in parse_body

canonical_body = function_body("canonicalizePipelineStages")
assert "!unique.contains(normalized)" in canonical_body
assert "orderedPipelineStageIds().findAll" in canonical_body

effective_body = function_body("effectivePipelineStages")
assert effective_body.count("canonicalizePipelineStages") >= 2
assert "addImplicitDeploymentStages(stages)" in effective_body

should_run_body = function_body("shouldRunAnsibleStage")
assert "PIPELINE_STAGES_RESOLVED" in should_run_body
assert "applyResolvedPipelineStages()" in should_run_body
assert "stage('ECS Cleanup — Destructive Rebuild')" in jenkinsfile
assert "runAnsibleDeployPhase('ecs_cleanup')" in jenkinsfile
assert "ECS_CLEANUP_CONFIRM=DELETE-ECS-CLUSTER-DATA" in jenkinsfile
assert "Use DRY_RUN=true for a preview without deletion." in jenkinsfile

resolved_body = function_body("applyResolvedPipelineStages")
assert "env.SELECTED_ANSIBLE_STAGES = cfg.selectedAnsibleStages" in resolved_body
assert "env.PIPELINE_STAGES_RESOLVED = 'true'" in resolved_body

order = [
    "VALIDATE",
    "TERRAFORM",
    "ECS_CLEANUP",
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
    values = value if isinstance(value, (list, tuple)) else [value]
    normalized = []
    for item in values:
        for token in str(item).split(","):
            token = token.strip().upper().replace("-", "_")
            token = aliases.get(token, token)
            if token and token not in normalized:
                normalized.append(token)
    result = [stage for stage in order if stage in normalized]
    return [stage for stage in order if stage in result]


assert effective("ECS_INSTALL,ECS_DATA_SERVICES") == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
assert effective("VALIDATE,ECS_CLEANUP,IDENTITY,ECS_INSTALL") == [
    "VALIDATE",
    "ECS_CLEANUP",
    "IDENTITY",
    "ECS_INSTALL",
]
assert effective([" ecs ", "DATA_SERVICES", "ecs-install", "dataservices"]) == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
assert effective("PORTAL,MONITORING,PORTAL") == ["PORTAL", "MONITORING"]
assert effective("MONITORING") == ["MONITORING"]
assert effective("CDH_INSTALL,CM_TLS") == [
    "CM_TLS_KRB_LDAP",
    "CDH_INSTALL",
]
assert effective(effective("ECS_INSTALL,ECS_DATA_SERVICES")) == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]

pvc_setup = (Path(sys.argv[1]).parent / "ansible-playbooks" / "pvc_setup.sh").read_text()
assert "ecs_data_services_sync_portal_routes=false" in pvc_setup
assert "ecs_data_services_sync_portal_routes=true" in pvc_setup
assert "_portal_actions_selected()" in pvc_setup
assert "ecs_cleanup|cleanup_ecs) run_phase_ecs_cleanup" in pvc_setup
assert "cleanup_cluster_services_remove_service_lib_dirs_input=true" in pvc_setup
assert 'ECS_CLEANUP_CONFIRM:-' in pvc_setup
assert "DELETE-ECS-CLUSTER-DATA" in pvc_setup

cleanup_playbook = (
    Path(sys.argv[1]).parent
    / "ansible-playbooks"
    / "98_cleanup_cluster_services.yml"
).read_text()
assert "Verify ECS runtime services are inactive after cleanup" in cleanup_playbook
assert "Require ingress host ports to be released after cleanup" in cleanup_playbook
assert "ECS cleanup left {{ item.item }} active" in cleanup_playbook
assert "ECS cleanup left ingress host port 80 or 443 occupied" in cleanup_playbook

print("Role branch Jenkins phase selection checks passed")
PY
