#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import json
import subprocess
import sys
import yaml

root = Path(sys.argv[1])
tasks = yaml.safe_load(
    (
        root
        / "ansible-playbooks/common_tasks/ecs_data_service_cdw_followup.yml"
    ).read_text()
)


def walk(items):
    for item in items:
        yield item
        for key in ("block", "rescue", "always"):
            nested = item.get(key, [])
            if isinstance(nested, list):
                yield from walk(nested)


task = next(
    item
    for item in walk(tasks)
    if item.get("name")
    == "Verify database catalog namespace health after stale API status"
)
script = task["ansible.builtin.command"]["argv"][2]


def pod(name, app, phase="Running", ready=True, owner_kind="StatefulSet"):
    return {
        "metadata": {
            "name": name,
            "labels": {"app": app},
            "ownerReferences": [{"kind": owner_kind}],
        },
        "spec": {"containers": [{"name": app}]},
        "status": {
            "phase": phase,
            "containerStatuses": [{"name": app, "ready": ready}],
        },
    }


def check(items, expected_rc):
    result = subprocess.run(
        ["python3", "-c", script],
        input=json.dumps({"items": items}),
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == expected_rc, result.stdout + result.stderr
    return json.loads(result.stdout)


healthy = check(
    [
        pod("metastore-0", "metastore"),
        pod("metastore-1", "metastore"),
        pod("hue-query-processor-0", "hue-query-processor"),
        pod(
            "hue-query-processor-db-create-job",
            "hue-query-processor",
            phase="Succeeded",
            ready=False,
            owner_kind="Job",
        ),
    ],
    0,
)
assert healthy["unhealthyPods"] == []
assert healthy["missingRequiredApps"] == []

not_ready = check(
    [
        pod("metastore-0", "metastore"),
        pod("hue-query-processor-0", "hue-query-processor", ready=False),
    ],
    3,
)
assert not_ready["unhealthyPods"] == ["hue-query-processor-0:ready=0/1"]

missing = check([pod("metastore-0", "metastore")], 3)
assert missing["missingRequiredApps"] == ["hue-query-processor"]

pending = check(
    [
        pod("metastore-0", "metastore"),
        pod(
            "hue-query-processor-0",
            "hue-query-processor",
            phase="Pending",
            ready=False,
        ),
    ],
    3,
)
assert pending["unhealthyPods"] == ["hue-query-processor-0:phase=Pending"]

print("CDW catalog Kubernetes health fallback checks passed")
PY
