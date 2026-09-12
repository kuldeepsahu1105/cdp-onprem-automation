#!/usr/bin/env python3
"""Static checks for Ansible variable dependencies (portal verify, CM API, set_fact pitfalls)."""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
COMMON_TASKS = REPO_ROOT / "ansible-playbooks" / "common_tasks"
PLAYBOOKS = REPO_ROOT / "ansible-playbooks"
GROUP_VARS = REPO_ROOT / "ansible-playbooks" / "group_vars"

SET_FACT_MODULE = re.compile(
    r"^\s+(?:ansible\.builtin\.)?set_fact:\s*$", re.MULTILINE
)
VERIFY_WHEN_VAR = re.compile(
    r"\b(_portal_[a-z0-9_]+|_acr_[a-z0-9_]+|deployment_portal_[a-z0-9_]+)\b"
)
SET_FACT_KEY = re.compile(r"^\s{4}([a-zA-Z_][a-zA-Z0-9_]*):\s")
TASK_MODULE_LINE = re.compile(r"^\s{2}(?:ansible\.builtin\.)?\w+:")


def iter_yaml_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.yml") if p.is_file())


def parse_set_fact_blocks(text: str) -> list[tuple[str, dict[str, str]]]:
    """Return (task_name, {key: value_text}) for each set_fact task."""
    lines = text.splitlines()
    blocks: list[tuple[str, dict[str, str]]] = []
    i = 0
    task_name = ""
    while i < len(lines):
        line = lines[i]
        if re.match(r"^\s+- name:", line):
            task_name = line.split(":", 1)[1].strip()
        if SET_FACT_MODULE.match(line):
            keys: dict[str, str] = {}
            i += 1
            while i < len(lines):
                ln = lines[i]
                if re.match(r"^\s+- name:", ln) or TASK_MODULE_LINE.match(ln):
                    break
                m = SET_FACT_KEY.match(ln)
                if m:
                    key = m.group(1)
                    val_lines = [ln.split(":", 1)[1].lstrip()]
                    i += 1
                    while i < len(lines):
                        nxt = lines[i]
                        if (
                            SET_FACT_KEY.match(nxt)
                            or re.match(r"^\s+- name:", nxt)
                            or TASK_MODULE_LINE.match(nxt)
                        ):
                            break
                        if re.match(r"^\s{4}\S", nxt) and not nxt.startswith(
                            "      "
                        ):
                            break
                        val_lines.append(nxt)
                        i += 1
                    keys[key] = "\n".join(val_lines)
                    continue
                i += 1
            if keys:
                blocks.append((task_name, keys))
            continue
        i += 1
    return blocks


def jinja_references_key(value: str, key: str) -> bool:
    if key not in value:
        return False
    esc = re.escape(key)
    patterns = [
        r"\{\{\s*" + esc,
        r"\{\{\s*" + esc + r"\s*\|",
        r"\(\s*" + esc,
        r"\s" + esc + r"\s*\|",
        r"\s" + esc + r"\s*\}\}",
        r"default\(\s*" + esc,
    ]
    return any(re.search(p, value) for p in patterns)


def check_same_task_set_fact(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    warnings: list[str] = []
    for task_name, keys in parse_set_fact_blocks(text):
        if len(keys) < 2:
            continue
        key_list = list(keys.keys())
        for k1 in key_list:
            for k2 in key_list:
                if k1 == k2:
                    continue
                if jinja_references_key(keys[k1], k2):
                    rel = path.relative_to(REPO_ROOT)
                    warnings.append(
                        f"{rel}: set_fact task {task_name!r} key {k1!r} "
                        f"references sibling key {k2!r} (split tasks or inline hostvars)"
                    )
    return warnings


def index_setters(search_roots: list[Path]) -> dict[str, set[str]]:
    """Map variable name -> files that appear to set it (set_fact, register, group_vars)."""
    index: dict[str, set[str]] = {}
    key_line = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*):\s", re.MULTILINE)

    for root in search_roots:
        for path in iter_yaml_files(root):
            text = path.read_text(encoding="utf-8")
            rel = str(path.relative_to(REPO_ROOT))
            if "set_fact" in text:
                for _task, keys in parse_set_fact_blocks(text):
                    for k in keys:
                        index.setdefault(k, set()).add(rel)
            for m in re.finditer(
                r"^\s+register:\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*$", text, re.MULTILINE
            ):
                index.setdefault(m.group(1), set()).add(rel)
            if path.parent.name == "group_vars":
                for m in key_line.finditer(text):
                    index.setdefault(m.group(1), set()).add(rel)
    return index


def extract_when_lines(text: str) -> list[str]:
    """Collect lines belonging to when: clauses (task-level, 2-space YAML)."""
    lines = text.splitlines()
    collected: list[str] = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        if re.match(r"^\s{2}when:\s*", ln):
            collected.append(ln)
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if TASK_MODULE_LINE.match(nxt) or re.match(r"^\s+- name:", nxt):
                    break
                if re.match(r"^\s{2}\w", nxt) and not re.match(r"^\s{4}", nxt):
                    break
                if re.match(r"^\s{4}", nxt) or re.match(r"^\s{6}", nxt):
                    collected.append(nxt)
                    i += 1
                    continue
                break
            continue
        i += 1
    return collected


def check_verify_when_setters() -> list[str]:
    verify_files = sorted(COMMON_TASKS.glob("verify_*.yml"))
    roots = [COMMON_TASKS, PLAYBOOKS, GROUP_VARS]
    setters = index_setters(roots)
    allow_no_setter = {
        "deployment_portal_verify_milestones",
        "deployment_portal_verify_post_cm",
        "deployment_portal_verify_cm_vhost",
        "deployment_portal_url_verify_status_codes",
        "deployment_portal_url_verify_skip_vpc",
        "deployment_portal_enabled",
        "deployment_portal_http_port",
        "deployment_portal_caddy_container",
        "deployment_portal_config_dir",
        "deployment_portal_cm_vhost_tier_a_verify",
        "deployment_portal_access_url_checks",
        "deployment_portal_access_url_checks_required",
        "deployment_portal_access_url_checks_optional",
        "deployment_portal_caddy_vhost_checks",
        "deployment_portal_caddy_vhost_checks_required",
        "deployment_portal_caddy_vhost_checks_optional",
        "deployment_portal_context",
        "deployment_portal_has_ipa",
        "deployment_portal_ipa_fqdn",
        "deployment_portal_cm_fqdn",
        "deployment_portal_anchor_inv",
        "ansible_control_reach_public_only",
        "ansible_control_reachability_effective",
    }
    contract_setters = {
        "_portal_verify_milestones_effective": "resolve_deployment_portal_verify_milestones.yml",
        "deployment_portal_verify_milestones_effective": "resolve_deployment_portal_verify_milestones.yml",
        "deployment_portal_context": "build_deployment_portal_facts.yml / deployment_portal_load_host_facts.yml",
        "deployment_portal_cm_http_probe": "probe_cm_manager_ui_http.yml / build_deployment_portal_facts.yml",
        "ansible_control_reach_public_only": "detect_ansible_control_reachability.yml",
    }
    warnings: list[str] = []
    for vpath in verify_files:
        rel = str(vpath.relative_to(REPO_ROOT))
        text = vpath.read_text(encoding="utf-8")
        local_setters = {k for _t, keys in parse_set_fact_blocks(text) for k in keys}
        when_blob = "\n".join(extract_when_lines(text))
        for m in VERIFY_WHEN_VAR.finditer(when_blob):
            var = m.group(1)
            if var in allow_no_setter or var in local_setters:
                continue
            if var in setters:
                continue
            if var in contract_setters:
                warnings.append(
                    f"{rel}: when: uses {var!r} — must be set earlier in play chain "
                    f"({contract_setters[var]}); see VARIABLE_CONTRACTS.md"
                )
            else:
                warnings.append(
                    f"{rel}: when: uses {var!r} but no set_fact/group_vars "
                    f"setter found in ansible-playbooks (check import order or "
                    f"VARIABLE_CONTRACTS.md)"
                )
    return warnings


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    if not COMMON_TASKS.is_dir():
        print("validate-ansible-contracts: common_tasks missing", file=sys.stderr)
        return 1

    for path in sorted(COMMON_TASKS.glob("*.yml")):
        warnings.extend(check_same_task_set_fact(path))

    warnings.extend(check_verify_when_setters())

    for w in sorted(set(warnings)):
        print(f"[validate-ansible-contracts] WARN: {w}", file=sys.stderr)

    for e in errors:
        print(f"[validate-ansible-contracts] ERROR: {e}", file=sys.stderr)

    n_warn = len(set(warnings))
    print(
        f"[validate-ansible-contracts] OK: scanned common_tasks set_fact heuristics "
        f"({n_warn} warning(s))"
    )
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
