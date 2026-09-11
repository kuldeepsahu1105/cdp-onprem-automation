#!/usr/bin/env python3
"""Build ansible-playbooks/group_vars/all/jenkins_override.yml from Jenkins/CLI inputs."""

from __future__ import annotations

import base64
import os
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

# Use Jenkins CM params instead of pasting these into the textarea.
TEXTAREA_BLOCKED_KEYS = frozenset({"cm_repo_username", "cm_repo_password"})


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
    overrides: dict = {}

    for env_key, var_name in ENV_TO_VAR:
        val = os.environ.get(env_key, "").strip()
        if val:
            overrides[var_name] = val

    textarea = _filter_textarea_overrides(_load_yaml_fragment(), allowed)
    overrides.update(textarea)
    overrides = _coerce_bool_strings(overrides)

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
        "# Merged over ansible-playbooks/group_vars/all.yml (group: all).\n"
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
