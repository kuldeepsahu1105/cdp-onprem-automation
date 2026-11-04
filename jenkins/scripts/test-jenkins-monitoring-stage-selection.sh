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

implicit_body = function_body("addImplicitDeploymentStages")
for token in (
    "CDH_INSTALL",
    "ECS_INSTALL",
    "PORTAL",
    "MONITORING",
    "DEPLOYMENT_PORTAL_ENABLED=true",
    "MONITORING_STACK_ENABLED=true",
):
    assert token in implicit_body
assert implicit_body.index("result << 'PORTAL'") < implicit_body.index(
    "result << 'MONITORING'"
)
assert "def monitoringTriggers = ['PORTAL']" in implicit_body
assert "adding MONITORING immediately after PORTAL" in implicit_body

effective_body = function_body("effectivePipelineStages")
assert "addImplicitDeploymentStages(expandPipelineStageTokens(stages))" in effective_body

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

print("Jenkins monitoring stage selection checks passed")
PY
