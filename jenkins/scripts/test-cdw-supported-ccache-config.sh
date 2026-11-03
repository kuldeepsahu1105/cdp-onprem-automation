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
followup_path = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_followup.yml"
)
followup = followup_path.read_text()
followup_tasks = yaml.safe_load(followup)
compatibility = (
    root / "ansible-playbooks/common_tasks/ecs_data_service_cdw_followup.yml"
).read_text()
group_vars = yaml.safe_load(
    (root / "ansible-playbooks/group_vars/all.yml").read_text()
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def decode_serialized_stdout(value):
    payload = json.loads(json.dumps(value))
    if isinstance(payload, str):
        payload = json.loads(payload)
    return payload


def walk(items):
    for item in items:
        yield item
        for key in ("block", "rescue", "always"):
            nested = item.get(key, [])
            if isinstance(nested, list):
                yield from walk(nested)


representative_config = {
    "config": {
        "commonConfigs": {
            "configBlocks": [
                {
                    "id": "env",
                    "content": {
                        "keyValues": {
                            "KRB5CCNAME": "FILE:/tmp/krb5cc_metastore"
                        }
                    },
                }
            ]
        }
    }
}
require(
    decode_serialized_stdout(representative_config) == representative_config,
    "native mapping stdout must survive JSON serialization",
)
require(
    decode_serialized_stdout(json.dumps(representative_config))
    == representative_config,
    "text stdout must survive JSON serialization and one JSON unwrap",
)
require(
    "ansible.builtin.import_role:" in compatibility
    and "name: ecs" in compatibility
    and "tasks_from: ecs_data_service_cdw_followup" in compatibility,
    "common task compatibility entry point must import the authoritative ECS role task",
)

parser_tasks = {
    item["name"]: item["ansible.builtin.command"]["argv"]
    for item in walk(followup_tasks)
    if item.get("name")
    in {
        "Check database catalog FILE credential cache configuration",
        "Verify database catalog namespace health after stale API status",
        "Check Virtual Warehouse FILE credential cache configurations",
    }
}
require(len(parser_tasks) == 3, "expected all three registered-stdout parser tasks")
for name, argv in parser_tasks.items():
    command = ["python3", "-c", argv[2]]
    if len(argv) > 3:
        command.append("FILE:/tmp/krb5cc_expected")
    malformed = subprocess.run(
        command,
        input="{not-json",
        text=True,
        capture_output=True,
        check=False,
    )
    require(
        malformed.returncode not in (0, 3),
        f"{name} must fail strictly for malformed JSON input",
    )

for command in (
    "'describe-dbc-config'",
    "'update-dbc'",
    "'create-vw'",
    "'describe-vw-config'",
    "'update-vw'",
):
    require(command in followup, f"missing supported CDW API command {command}")

require(
    "ecs_cdw_dbc_file_ccache_config | to_json" in followup,
    "DBC update must use the shared FILE-cache config",
)
require(
    followup.count("ecs_cdw_vw_file_ccache_config | to_json") == 2,
    "VW create and update must use the shared FILE-cache config",
)
require(
    followup.count('.get("KRB5CCNAME", "")') == 2,
    "DBC and VW configuration must be inspected idempotently",
)
require(
    followup.count("if isinstance(payload, str):") == 3
    and followup.count("payload = json.loads(payload)") == 3,
    "JSON parsers must unwrap registered stdout when Ansible preserves it as text",
)
require(
    'stdin: "{{ ecs_cdw_dbc_config.stdout | to_json }}"' in followup,
    "DBC config must cross the command stdin boundary as JSON",
)
require(
    'stdin: "{{ item.stdout | to_json }}"' in followup,
    "VW config must cross the command stdin boundary as JSON",
)
require(
    "ecs_cdw_catalog_kubernetes_pods.stdout" in followup
    and "| default({})" in followup
    and followup.count("| to_json") >= 8,
    "Kubernetes health input must cross the command stdin boundary as JSON",
)
require(
    "failed_when: ecs_cdw_dbc_ccache_check.rc not in [0, 3]" in followup,
    "DBC comparison must distinguish equal from update-required",
)
require(
    "failed_when: ecs_cdw_vw_ccache_checks.rc not in [0, 3]" in followup,
    "VW comparison must distinguish equal from update-required",
)
require(
    followup.index("Persist database catalog FILE credential cache through CDW API")
    < followup.index("\n    - name: Wait for default database catalog\n"),
    "DBC cache must be configured before waiting for Running",
)
require(
    followup.index("Persist Virtual Warehouse FILE credential caches through CDW API")
    < followup.index("Wait for desired CDW Virtual Warehouses to finish provisioning"),
    "existing VW caches must be configured before terminal waits",
)

for forbidden in (
    "kubectl set env",
    "statefulset/metastore",
    "delete pod",
    "rollout status",
    "ecs_data_service_cdw_reconcile_workload_ccache.yml",
    "ecs_data_service_cdw_reconcile_vw_ccaches.yml",
):
    require(forbidden not in followup, f"forbidden controller mutation remains: {forbidden}")

for option in (
    "'--impala-options'",
    "'--impala-ha-settings'",
    "'--autoscaling'",
    "'--additional-quota'",
    "'--impala-query-log'",
    "'--no-impala-query-log'",
):
    require(option in followup, f"missing configurable Impala option {option}")

require(
    "Validate configured Trino Virtual Warehouse settings" in followup,
    "Trino settings must be validated before creation",
)
require(
    "ecs_cdw_trino_autoscaling | to_json" in followup,
    "configured Trino autoscaling must be passed to create-vw",
)
require(
    "ecs_cdw_trino_additional_quota | to_json" in followup,
    "configured Trino additional quota must be passed to create-vw",
)

require(
    group_vars["ecs_cdw_workload_krb5ccname"]
    == "FILE:/tmp/krb5cc_metastore",
    "DBC cache path changed",
)
require(
    group_vars["ecs_cdw_vw_krb5ccname"] == "FILE:/tmp/krb5cc_cdw",
    "VW cache path changed",
)
require(
    group_vars["ecs_cdw_dbc_file_ccache_config"]["commonConfigs"]["configBlocks"][0]
    ["content"]["keyValues"]["KRB5CCNAME"]
    == "{{ ecs_cdw_workload_krb5ccname }}",
    "DBC config must reference the authoritative variable",
)
require(
    group_vars["ecs_cdw_vw_file_ccache_config"]["commonConfigs"]["configBlocks"][0]
    ["content"]["keyValues"]["KRB5CCNAME"]
    == "{{ ecs_cdw_vw_krb5ccname }}",
    "VW config must reference the authoritative variable",
)
require(group_vars["ecs_cdw_vw_tshirt_size"] == "xsmall", "minimum size changed")
require(
    group_vars["ecs_cdw_vw_resource_pool"]
    == "root.{{ ecs_cdp_environment_name }}.cdw",
    "CDW resource pool changed",
)
require(
    group_vars["ecs_cdw_impala_ha_settings"]["highAvailabilityMode"]
    == "DISABLED",
    "Impala HA default changed",
)
require(
    group_vars["ecs_cdw_impala_autoscaling"]["minClusters"] == 1
    and group_vars["ecs_cdw_impala_autoscaling"]["maxClusters"] == 5,
    "Impala autoscaling defaults changed",
)
require(
    group_vars["ecs_cdw_impala_query_log"] is True,
    "Impala query logging default changed",
)
require(
    group_vars["ecs_cdw_trino_autoscaling"] == {},
    "Trino autoscaling must remain empty by default",
)
require(
    group_vars["ecs_cdw_trino_additional_quota"] == {"cpu": 0.0, "memory": 0},
    "Trino additional quota defaults changed",
)

print("CDW supported API ccache and warehouse setting checks passed")
PY
