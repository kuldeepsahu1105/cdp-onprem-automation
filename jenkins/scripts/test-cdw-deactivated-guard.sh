#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
preflight = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cdw_preflight.yml"
).read_text()
wait = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cdw_wait.yml"
).read_text()
result = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cdw.yml"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


selector = "selectattr('status', 'search', '(?i)^deactivated$')"
require(selector in preflight, "preflight must select exactly Deactivated")
require(
    "ecs_cdw_deactivated_clusters | default([]) | length == 0" in preflight,
    "preflight must reject selected Deactivated records",
)

guard_start = preflight.index("- name: CDW | Select deactivated cluster records")
mutation_start = preflight.index(
    "- name: CDW | Ensure FreeIPA host principal prerequisite"
)
require(
    guard_start < mutation_start,
    "Deactivated rejection must run before FreeIPA principal mutation",
)
guard = preflight[guard_start:mutation_start]
normalized_guard = " ".join(guard.split())
for fragment in (
    "pinned cloudera.cloud",
    "cannot reactivate an existing Deactivated cluster",
    "t-shirt-sizes endpoint",
    "HTTP 404",
    "did not submit the activation POST",
    "supported DWX UI/backend activation path",
    "activate the cluster manually",
    "then rerun",
):
    require(fragment in normalized_guard, f"missing operator guidance: {fragment}")

require(
    "is search('(?i)^(running|error|failed|deactivated)$')" in wait,
    "structured polling must terminate on Deactivated",
)
require(
    ".status | default('') == 'Running'" in result,
    "only Running may pass the final CDW success check",
)


def preflight_rejects(status: str) -> bool:
    return re.search(r"(?i)^deactivated$", status) is not None


def wait_terminates(status: str) -> bool:
    return re.search(r"(?i)^(running|error|failed|deactivated)$", status) is not None


def result_succeeds(status: str) -> bool:
    return status == "Running"


for status in ("Deactivated", "deactivated", "DEACTIVATED"):
    require(preflight_rejects(status), f"preflight did not reject {status}")
for status in ("Running", "Deactivated ", "PreviouslyDeactivated"):
    require(not preflight_rejects(status), f"preflight overmatched {status!r}")

require(wait_terminates("Deactivated"), "wait must terminate on Deactivated")
require(wait_terminates("Running"), "wait must terminate on Running")
require(not wait_terminates("Installing"), "wait must continue on Installing")
require(result_succeeds("Running"), "Running must remain successful")
require(not result_succeeds("Deactivated"), "Deactivated must not be successful")

for content, label in ((guard, "preflight guard"), (wait, "wait helper")):
    require(
        "cloudera.cloud.dw_cluster:" not in content,
        f"{label} must not add a cluster activation/reconciliation call",
    )
    require("state: absent" not in content, f"{label} must not delete")
    require("state: restarted" not in content, f"{label} must not restart")

print("CDW Deactivated guard static/mock checks passed")
PY
