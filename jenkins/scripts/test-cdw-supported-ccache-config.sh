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
vw_tasks_path = (
    root
    / "ansible-playbooks/roles/ecs/tasks/ecs_data_service_cdw_virtual_warehouse.yml"
)
vw_tasks = vw_tasks_path.read_text()
vw_task_list = yaml.safe_load(vw_tasks)
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
        "applicationConfigs": {
            "metastore": {
                "configBlocks": [
                    {
                        "id": "env",
                        "content": {
                            "keyValues": {
                                "SERVICE_OPTS": "-javaagent:/opt/jmx.jar"
                            }
                        },
                    }
                ]
            }
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
    }
}
require(len(parser_tasks) == 2, "expected both registered-stdout parser tasks")
dbc_patch = {
    "applicationConfigs": {
        "metastore": {
            "configBlocks": [
                {
                    "id": "env",
                    "content": {
                        "keyValues": {
                            "KRB5CCNAME": "FILE:/tmp/krb5cc_expected"
                        }
                    },
                }
            ]
        }
    }
}
for name, argv in parser_tasks.items():
    command = ["python3", "-c", argv[2]]
    if len(argv) > 3:
        command.append(json.dumps(dbc_patch))
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

merge_task = next(
    item
    for item in walk(followup_tasks)
    if item.get("name")
    == "Merge database catalog FILE cache into live metastore configuration"
)
merged = subprocess.run(
    ["python3", "-c", merge_task["ansible.builtin.command"]["argv"][2], json.dumps(dbc_patch)],
    input=json.dumps(representative_config),
    text=True,
    capture_output=True,
    check=True,
)
merged_config = json.loads(merged.stdout)
merged_values = merged_config["applicationConfigs"]["metastore"]["configBlocks"][0][
    "content"
]["keyValues"]
require(
    merged_values["SERVICE_OPTS"] == "-javaagent:/opt/jmx.jar"
    and merged_values["KRB5CCNAME"] == "FILE:/tmp/krb5cc_expected",
    "DBC live-config merge must preserve SERVICE_OPTS while adding KRB5CCNAME",
)
require(
    set(merged_config) == {"applicationConfigs"}
    and set(merged_config["applicationConfigs"]) == {"metastore"}
    and len(
        merged_config["applicationConfigs"]["metastore"]["configBlocks"]
    ) == 1,
    "DBC update must send only the minimal metastore env patch",
)

for command in (
    "'describe-dbc-config'",
    "'update-dbc'",
    "'start-dbc'",
):
    require(command in followup, f"missing supported CDW API command {command}")
require("'create-vw'" in vw_tasks, "missing supported CDW API command 'create-vw'")

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
    followup.count("ecs_cdw_dbc_file_ccache_config_effective.stdout") == 2
    and followup.count("ecs_cdw_dbc_file_ccache_config | to_json") == 2,
    "DBC updates must use a live-config merge driven by the shared FILE-cache config",
)
require(
    vw_tasks.count("ecs_cdw_vw_file_ccache_config | to_json") == 1,
    "VW creation must use the shared FILE-cache config exactly once",
)
require(
    followup.count('.get("KRB5CCNAME", "")') == 3,
    "DBC configuration must be inspected before, during, and after reconciliation",
)
require(
    followup.count("if isinstance(payload, str):") == 5
    and followup.count("payload = json.loads(payload)") == 5,
    "JSON parsers must unwrap registered stdout when Ansible preserves it as text",
)
require(
    "Merge database catalog FILE cache into live metastore configuration" in followup
    and 'config.get("applicationConfigs", {})' in followup
    and "copy.deepcopy(block)" in followup
    and '"configBlocks": [env]' in followup
    and 'key_values["KRB5CCNAME"] = desired' in followup,
    "DBC reconciliation must build a minimal metastore patch from the live env config",
)
require(
    'stdin: "{{ ecs_cdw_dbc_config.stdout | to_json }}"' in followup,
    "DBC config must cross the command stdin boundary as JSON",
)
require(
    'stdin: "{{ ecs_cdw_dbc_config_converged.stdout | to_json }}"' in followup,
    "converged DBC config must be verified across the command stdin boundary",
)
require(
    "Read converged database catalog service configuration" in followup
    and 'is search(\'"id"\\s*:\\s*"env"\')' in followup
    and '\'"KRB5CCNAME"\\s*:\\s*"\''
    in followup
    and "ecs_cdw_workload_krb5ccname | regex_escape" in followup
    and 'retries: "{{ ecs_cdw_workload_refresh_retries | int }}"' in followup,
    "converged DBC reads must poll through CDW configuration propagation until "
    "the env FILE-cache block is visible",
)
require(
    "ecs_cdw_catalog_kubernetes_pods.stdout" in followup
    and "| default({})" in followup
    and (followup + vw_tasks).count("| to_json") >= 8,
    "Kubernetes health input must cross the command stdin boundary as JSON",
)
require(
    "failed_when: ecs_cdw_dbc_ccache_check.rc not in [0, 3]" in followup,
    "DBC comparison must distinguish equal from update-required",
)
require(
    "'--force-refresh'" in followup
    and "Verify generated metastore FILE credential cache" in followup,
    "persisted DBC config must force-refresh and verify the generated metastore pod",
)
require(
    "failed to acquire lease|already leased by operation" in followup
    and "operation is not allowed in '(starting|stopping|updating)' state"
    in followup
    and "Require database catalog FILE cache update" in followup
    and "ecs_cdw_workload_refresh_retries" in followup,
    "transient DBC update leases and lifecycle states must be retried within "
    "the bounded refresh window",
)
require(
    "Detect fresh catalog FILE cache bootstrap requirement" in followup
    and "Read initial generated metastore FILE credential cache" in followup
    and "Read initial generated metastore readiness" in followup
    and "Read initial generated metastore logs" in followup
    and "Read previous generated metastore logs" in followup
    and "is not search(" in followup
    and "running|stopped|suspended|deactivated|" in followup
    and "Keep metastore on FILE cache until CDW persists the catalog setting"
    in followup
    and "Persist database catalog FILE credential cache through CDW API" in followup
    and "statefulset/metastore" in followup
    and "pod/metastore-0" in followup
    and "--ignore-not-found=true" in followup
    and "pod_exists=false" in followup
    and "pod_ready=" in followup
    and "No KCM server|default ccache.*KCM|KCM server" in followup
    and "config_is_converged" in followup
    and "operation is not allowed in '(starting|stopping|updating)' state"
    in followup,
    "fresh catalogs in Starting or Updating with a stale metastore pod must "
    "keep the FILE cache applied until the supported API persists it",
)
require(
    followup.index(
        "Keep metastore on FILE cache until CDW persists the catalog setting"
    )
    < followup.index("Persist database catalog FILE credential cache through CDW API"),
    "fresh catalog metastore bootstrap must precede the first update-dbc attempt",
)
require(
    followup.index("delete pod/metastore-0 --wait=false --ignore-not-found=true")
    < followup.index("if [[ ${config_rc} -eq 0 ]] && config_is_converged"),
    "fresh catalog recovery must repair a stale generated pod before accepting "
    "an already-persisted API setting",
)
refresh_section = followup.split(
    "- name: Refresh database catalog workloads after FILE cache reconciliation",
    1,
)[1].split("- name: Require database catalog workload refresh", 1)[0]
require(
    "ecs_cdw_dbc_ccache_guarded_update" not in refresh_section,
    "fresh guarded recovery must not force-refresh a catalog in Accepted or "
    "another natural activation state",
)
require(
    "ecs_cdw_dbc_ccache_update" not in refresh_section
    and "ecs_cdw_metastore_krb5ccname" not in refresh_section,
    "a successful config update or generated-pod mismatch must not call "
    "start-dbc for an already Running catalog",
)
require(
    "another operation[^\\\\n]*already in progress" in followup
    and "can't start DB Catalog in status " in followup
    and "'(starting|stopping|updating)'" in followup
    and "Require database catalog workload refresh" in followup,
    "transient DBC start leases and lifecycle states must be retried before "
    "catalog readiness checks",
)
require(
    "ecs_cdw_catalog_initial_status" in followup
    and "stopped|suspended|deactivated" in followup,
    "stopped catalogs must be started even when config and pods are already converged",
)
require(
    followup.index("Persist database catalog FILE credential cache through CDW API")
    < followup.index("\n    - name: Wait for default database catalog\n"),
    "DBC cache must be configured before waiting for Running",
)
for forbidden in (
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
    require(option in vw_tasks, f"missing configurable Impala option {option}")

for unsupported_private_option in (
    "'--impala-query-log'",
    "'--no-impala-query-log'",
):
    require(
        unsupported_private_option not in vw_tasks,
        f"public-only option must not be submitted to private CDP: {unsupported_private_option}",
    )

require(
    "Validate configured Trino Virtual Warehouse settings" in followup,
    "Trino settings must be validated before creation",
)
require(
    "ecs_cdw_trino_autoscaling | to_json" in vw_tasks,
    "configured Trino autoscaling must be passed to create-vw",
)
require(
    "ecs_cdw_trino_additional_quota | to_json" in vw_tasks,
    "configured Trino additional quota must be passed to create-vw",
)
require(
    "Converge CDW Virtual Warehouses sequentially" in followup
    and "loop_var: ecs_cdw_vw" in followup,
    "Virtual Warehouses must be converged one at a time in deterministic order",
)
vw_task_names = [task["name"] for task in vw_task_list]
require(
    vw_task_names.index("CDW VW | Inspect {{ ecs_cdw_vw.type }} Virtual Warehouse")
    < vw_task_names.index("CDW VW | Create missing {{ ecs_cdw_vw.type }} Virtual Warehouse")
    < vw_task_names.index("CDW VW | Wait for {{ ecs_cdw_vw.type }} terminal status")
    < vw_task_names.index("CDW VW | Require healthy {{ ecs_cdw_vw.type }} Virtual Warehouse"),
    "each Virtual Warehouse must be inspected, created, and verified before the next",
)
require(
    "running|stopped|suspended|failed|error" in vw_tasks
    and "running|stopped|suspended" in vw_tasks,
    "Virtual Warehouse waits must accept healthy autosuspended rerun states",
)

require(
    group_vars["ecs_cdw_workload_krb5ccname"]
    == "FILE:/tmp/krb5cc_metastore",
    "DBC cache path changed",
)
require(
    group_vars["ecs_cdw_workload_refresh_retries"] == 60
    and group_vars["ecs_cdw_workload_refresh_delay"] == 10,
    "DBC workload refresh wait must remain bounded to ten minutes",
)
require(
    group_vars["ecs_cdw_vw_krb5ccname"] == "FILE:/tmp/krb5cc_cdw",
    "VW cache path changed",
)
require(
    "format"
    not in group_vars["ecs_cdw_dbc_file_ccache_config"]["applicationConfigs"][
        "metastore"
    ]["configBlocks"][0],
    "DBC payload must match pinned CLI schema (id/content only)",
)
require(
    group_vars["ecs_cdw_dbc_file_ccache_config"]["applicationConfigs"]["metastore"][
        "configBlocks"
    ][0]
    ["content"]["keyValues"]["KRB5CCNAME"]
    == "{{ ecs_cdw_workload_krb5ccname }}",
    "DBC config must reference the authoritative variable",
)
require(
    "format"
    not in group_vars["ecs_cdw_vw_file_ccache_config"]["commonConfigs"][
        "configBlocks"
    ][0],
    "Virtual Warehouse payload must match pinned CLI schema (id/content only)",
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
