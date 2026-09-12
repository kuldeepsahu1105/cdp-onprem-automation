#!/usr/bin/env python3
"""Build ansible-playbooks/jenkins_override.yml from Jenkins/CLI inputs (applied via -e @file)."""

from __future__ import annotations

import base64
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: python3 PyYAML required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]
ALLOWED_KEYS_FILE = REPO_ROOT / "jenkins" / "ansible-group-vars-allowed-keys.yaml"

# Jenkins env vars only (not accepted from ANSIBLE_GROUP_VARS_YAML textarea).
ENV_TO_VAR = [
    ("CM_REPO_USERNAME", "cm_repo_username"),
    ("CM_REPO_PASSWORD", "cm_repo_password"),
]

# Jenkins booleanParam values (applied after textarea; override all.yml and textarea).
BOOL_ENV_TO_VAR = [
    ("MONITORING_STACK_ENABLED", "monitoring_stack_enabled"),
    ("CM_API_PREFER_PRIVATE_IP", "cm_api_prefer_private_ip"),
    ("ANSIBLE_CONTROLLER_OUTSIDE_VPC", "ansible_controller_outside_vpc"),
    ("DEPLOYMENT_PORTAL_URL_VERIFY_SKIP_VPC", "deployment_portal_url_verify_skip_vpc"),
]

# Use Jenkins CM params instead of pasting these into the textarea.
TEXTAREA_BLOCKED_KEYS = frozenset({"cm_repo_username", "cm_repo_password"})

_RFC1918_HOST = re.compile(
    r"^(?:10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.)"
)


def _running_on_jenkins() -> bool:
    return bool(os.environ.get("BUILD_NUMBER") or os.environ.get("JENKINS_URL"))


def _inventory_first_public_ip(group: str, inventory_path: Path) -> str:
    if not inventory_path.is_file():
        return ""
    in_group = False
    for raw in inventory_path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            in_group = line[1:-1].strip() == group
            continue
        if not in_group:
            continue
        for token in line.split():
            if token.startswith("ansible_host="):
                host = token.split("=", 1)[1].strip().strip("'\"")
                if host and not _RFC1918_HOST.match(host):
                    return host
        break
    return ""


def _normalize_deployment_portal_http_port(overrides: dict) -> None:
    """Legacy labs used Caddy on :8088; repo default is :80 (group_vars/all.yml)."""
    port = overrides.get("deployment_portal_http_port")
    if port in (8088, "8088"):
        print(
            "[ansible-vars] WARN: deployment_portal_http_port 8088 is deprecated; using 80 "
            "(remove 8088 from ANSIBLE_GROUP_VARS_YAML)",
            file=sys.stderr,
        )
        overrides["deployment_portal_http_port"] = 80


def _jenkins_controller_defaults() -> dict:
    """Ansible from Jenkins cannot reach VPC RFC1918 addresses — use public IPs / delegate probes."""
    if not _running_on_jenkins():
        return {}
    defaults: dict = {
        "ansible_control_reachability": "public",
        "ansible_controller_outside_vpc": True,
        "cm_api_prefer_private_ip": False,
        "deployment_portal_url_verify_skip_vpc": True,
        "deployment_external_url_verify": "warn",
        "deployment_portal_external_url_verify": "warn",
        "deployment_ipa_direct_fqdn_external_url_verify": "skip",
        "cm_api_verify_mode": "warn",
        # Caddy edge on ops (ipaserver) for portal/pgAdmin/monitoring/IPA — not 8088. CM API uses :7180/:7183.
        "deployment_portal_http_port": 80,
    }
    inv = REPO_ROOT / "ansible-playbooks" / "inventory.ini"
    cm_public = _inventory_first_public_ip("cldr-mngr", inv)
    if cm_public:
        defaults["cm_api_connect_host"] = cm_public
    return defaults


def _load_allowed_keys() -> frozenset[str]:
    if not ALLOWED_KEYS_FILE.is_file():
        print(f"ERROR: allowed-keys file missing: {ALLOWED_KEYS_FILE}", file=sys.stderr)
        sys.exit(1)
    data = yaml.safe_load(ALLOWED_KEYS_FILE.read_text(encoding="utf-8"))
    keys = data.get("allowed_keys") if isinstance(data, dict) else None
    if not isinstance(keys, list) or not keys:
        print(f"ERROR: {ALLOWED_KEYS_FILE} must define allowed_keys: [ ... ]", file=sys.stderr)
        sys.exit(1)
    return frozenset(str(k) for k in keys)


def _load_yaml_fragment() -> dict:
    raw = os.environ.get("ANSIBLE_GROUP_VARS_YAML", "").strip()
    b64 = os.environ.get("ANSIBLE_GROUP_VARS_YAML_B64", "").strip()
    if b64:
        raw = base64.b64decode(b64).decode("utf-8", errors="replace").strip()
    path = os.environ.get("ANSIBLE_GROUP_VARS_FILE", "").strip()
    if path and Path(path).is_file():
        raw = Path(path).read_text(encoding="utf-8")
    if not raw:
        return {}
    data = yaml.safe_load(raw)
    if data is None:
        return {}
    if not isinstance(data, dict):
        print("ERROR: ANSIBLE_GROUP_VARS_YAML must be a YAML mapping (key: value)", file=sys.stderr)
        sys.exit(1)
    return data


def _filter_textarea_overrides(data: dict, allowed: frozenset[str]) -> dict:
    rejected: list[str] = []
    filtered: dict = {}
    for key, val in data.items():
        if key in TEXTAREA_BLOCKED_KEYS:
            rejected.append(
                f"{key} (use Jenkins CM_REPO_USERNAME / CM_REPO_PASSWORD instead)"
            )
            continue
        if key not in allowed:
            rejected.append(key)
            continue
        filtered[key] = val
    if rejected:
        print(
            "ERROR: ANSIBLE_GROUP_VARS_YAML contains keys that are not allowed:\n  "
            + "\n  ".join(sorted(rejected)),
            file=sys.stderr,
        )
        print(
            f"Allowed keys are listed in {ALLOWED_KEYS_FILE.relative_to(REPO_ROOT)}",
            file=sys.stderr,
        )
        sys.exit(1)
    return filtered


def _coerce_bool_strings(data: dict) -> dict:
    out = {}
    for key, val in data.items():
        if isinstance(val, str):
            low = val.lower()
            if low in ("true", "yes", "on"):
                out[key] = True
                continue
            if low in ("false", "no", "off"):
                out[key] = False
                continue
        out[key] = val
    return out


def main() -> int:
    validate_only = False
    args = sys.argv[1:]
    if args and args[0] == "--validate-only":
        validate_only = True
        args = args[1:]

    if len(args) != 1:
        print(
            f"Usage: {sys.argv[0]} [--validate-only] <output-jenkins_override.yml>",
            file=sys.stderr,
        )
        return 2

    out_path = Path(args[0])
    allowed = _load_allowed_keys()
    overrides: dict = _coerce_bool_strings(
        _filter_textarea_overrides(_load_yaml_fragment(), allowed)
    )

    for env_key, var_name in ENV_TO_VAR:
        val = os.environ.get(env_key, "").strip()
        if val:
            overrides[var_name] = val

    for env_key, var_name in BOOL_ENV_TO_VAR:
        if env_key not in os.environ:
            continue
        raw = os.environ.get(env_key, "").strip().lower()
        if raw in ("", "auto"):
            continue
        overrides[var_name] = raw in ("true", "1", "yes", "on")

    _normalize_deployment_portal_http_port(overrides)

    # Jenkins controller safety defaults win over ANSIBLE_GROUP_VARS_YAML (e.g. cm_api_verify_mode: warn).
    overrides.update(_jenkins_controller_defaults())

    if validate_only:
        print(f"[ansible-vars] YAML override keys OK ({len(textarea)} from textarea)")
        return 0

    if not overrides:
        if out_path.is_file():
            out_path.unlink()
        print("[ansible-vars] No overrides — using group_vars/all.yml only")
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "# Generated at runtime — do not commit.\n"
        "# Applied via ansible -e @file (merged over group_vars/all.yml).\n"
    )
    out_path.write_text(
        header + yaml.safe_dump(overrides, default_flow_style=False, sort_keys=False),
        encoding="utf-8",
    )

    print(f"[ansible-vars] Wrote {len(overrides)} override(s) to {out_path}")
    for key in sorted(overrides):
        if "password" in key.lower() or key.endswith("_pass"):
            print(f"[ansible-vars]   {key}=***")
        else:
            print(f"[ansible-vars]   {key}={overrides[key]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
