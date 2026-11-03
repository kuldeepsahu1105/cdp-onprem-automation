#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$repo_root" <<'PY'
from pathlib import Path
import json
import sys
import yaml

root = Path(sys.argv[1])
followup = (
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

for command in (
    "'describe-dbc-config'",
    "'update-dbc'",
    "'create-vw'",
):
    require(command in followup, f"missing supported CDW API command {command}")

for unsupported_vw_update in (
    "'describe-vw-config'",
    "'update-vw'",
    "ecs_cdw_vw_ccache_checks",
):
    require(
        unsupported_vw_update not in followup,
        f"creation-only Virtual Warehouse config must not be reconciled: {unsupported_vw_update}",
    )

require(
    "ecs_cdw_dbc_file_ccache_config | to_json" in followup,
    "DBC update must use the shared FILE-cache config",
)
require(
    followup.count("ecs_cdw_vw_file_ccache_config | to_json") == 1,
    "VW creation must use the shared FILE-cache config exactly once",
)
require(
    followup.count('.get("KRB5CCNAME", "")') == 1,
    "DBC configuration must be inspected idempotently",
)
require(
    followup.count("if isinstance(payload, str):") == 2
    and followup.count("payload = json.loads(payload)") == 2,
    "JSON parsers must unwrap registered stdout when Ansible preserves it as text",
)
require(
    'stdin: "{{ ecs_cdw_dbc_config.stdout | to_json }}"' in followup,
    "DBC config must cross the command stdin boundary as JSON",
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
    followup.index("Persist database catalog FILE credential cache through CDW API")
    < followup.index("\n    - name: Wait for default database catalog\n"),
    "DBC cache must be configured before waiting for Running",
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
):
    require(option in followup, f"missing configurable Impala option {option}")

for unsupported_private_option in (
    "'--impala-query-log'",
    "'--no-impala-query-log'",
):
    require(
        unsupported_private_option not in followup,
        f"public-only option must not be submitted to private CDP: {unsupported_private_option}",
    )

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
    "ecs_cdw_impala_query_log" not in group_vars,
    "public-only Impala query logging option must not be configurable",
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
