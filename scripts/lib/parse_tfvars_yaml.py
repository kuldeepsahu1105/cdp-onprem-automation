#!/usr/bin/env python3
"""Parse .tfvars.yaml and print shell export statements for wrapper scripts."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def _ensure_yaml():
    try:
        import yaml  # type: ignore
    except ImportError:
        import subprocess

        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "-q", "pyyaml"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        import yaml  # type: ignore

    return yaml


# YAML keys (snake_case) -> shell variable names (historical UPPER_SNAKE)
KEY_MAP = {
    "aws_region": "AWS_REGION",
    "owner": "OWNER",
    "environment": "ENVIRONMENT",
    "terraform_version": "TERRAFORM_VERSION",
    "cm_version": "CM_VERSION",
    "existing_sg_name": "EXISTING_SG_NAME",
    "existing_keypair_name": "EXISTING_KEYPAIR_NAME",
    "ami_id": "AMI_ID",
    "cpu_architecture": "CPU_ARCHITECTURE",
    "apply_graviton_defaults": "APPLY_GRAVITON_DEFAULTS",
    "auto_resolve_arm64_ami": "AUTO_RESOLVE_ARM64_AMI",
    "ecs_deploy_on_arm64": "ECS_DEPLOY_ON_ARM64",
}

INSTANCE_GROUP_MAP = {
    "cldr_mngr": "CLDR_MNGR",
    "ipa_server": "IPA_SERVER",
    "pvcbase_master": "PVCBASE_MASTER",
    "pvcbase_worker": "PVCBASE_WORKER",
    "pvcecs_master": "PVCECS_MASTER",
    "pvcecs_worker": "PVCECS_WORKER",
}


def _shell_quote(value: str) -> str:
    return json.dumps(value)


def _export(name: str, value) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        value = "true" if value else "false"
    return f"export {name}={_shell_quote(str(value))}"


def _flatten_instance_groups(groups: dict) -> list[str]:
    lines: list[str] = []
    for group_key, prefix in INSTANCE_GROUP_MAP.items():
        group = groups.get(group_key)
        if not isinstance(group, dict):
            continue
        if "count" in group:
            lines.append(_export(f"{prefix}_COUNT", group["count"]))
        if "instance_type" in group:
            lines.append(_export(f"{prefix}_INSTANCE_TYPE", group["instance_type"]))
        if "volume_size" in group:
            lines.append(_export(f"{prefix}_VOLUME_SIZE", group["volume_size"]))
        if "ami" in group:
            lines.append(_export("AMI_ID", group["ami"]))
    return [line for line in lines if line]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse_tfvars_yaml.py <path-to-yaml>", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 1

    yaml = _ensure_yaml()
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}

    if not isinstance(data, dict):
        print("error: root YAML document must be a mapping", file=sys.stderr)
        return 1

    lines: list[str] = []
    for yaml_key, env_name in KEY_MAP.items():
        if yaml_key in data:
            lines.append(_export(env_name, data[yaml_key]))

    instance_groups = data.get("instance_groups")
    if isinstance(instance_groups, dict):
        lines.extend(_flatten_instance_groups(instance_groups))

    print("\n".join(line for line in lines if line))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
