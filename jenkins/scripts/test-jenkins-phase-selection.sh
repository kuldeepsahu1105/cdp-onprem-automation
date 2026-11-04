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
assert "csv.getClass().isArray()" in parse_body

canonical_body = function_body("canonicalizePipelineStages")
assert "!unique.contains(normalized)" in canonical_body
assert "orderedPipelineStageIds().findAll" in canonical_body

effective_body = function_body("effectivePipelineStages")
assert effective_body.count("canonicalizePipelineStages") >= 3
assert "expandPipelineStageTokens(stages)" in effective_body

should_run_body = function_body("shouldRunAnsibleStage")
assert "PIPELINE_STAGES_RESOLVED" in should_run_body
assert "applyResolvedPipelineStages()" in should_run_body

resolved_body = function_body("applyResolvedPipelineStages")
assert "env.SELECTED_ANSIBLE_STAGES = cfg.selectedAnsibleStages" in resolved_body
assert "env.PIPELINE_STAGES_RESOLVED = 'true'" in resolved_body

order = [
    "VALIDATE",
    "TERRAFORM",
    "PREREQS",
    "PORTAL",
    "IDENTITY",
    "CM_INSTALL",
    "CM_TLS_KRB_LDAP",
    "CDH_INSTALL",
    "MONITORING",
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
            expanded = (
                ["CM_TLS_KRB_LDAP", "CDH_INSTALL"]
                if token == "CDH_BASE"
                else [token]
            )
            for stage in expanded:
                if stage and stage not in normalized:
                    normalized.append(stage)
    return [stage for stage in order if stage in normalized]


assert effective("ECS_INSTALL,ECS_DATA_SERVICES") == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
assert effective([" ecs ", "DATA_SERVICES", "ecs-install", "dataservices"]) == [
    "ECS_INSTALL",
    "ECS_DATA_SERVICES",
]
assert effective("PORTAL,MONITORING,PORTAL") == ["PORTAL", "MONITORING"]
assert effective("CDH_BASE,CDH_INSTALL,CM_TLS") == [
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

print("Role branch Jenkins phase selection checks passed")
PY
