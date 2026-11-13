#!/usr/bin/env bash
# Unit checks for jenkins_plain ok-host summarization (no Ansible run required).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PLUGIN="$REPO_ROOT/ansible-playbooks/callback_plugins/jenkins_plain.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 - <<'PY' "$PLUGIN" "$REPO_ROOT"
import importlib.util
from pathlib import Path
import sys
import types

path = sys.argv[1]
root = Path(sys.argv[2])
try:
    from ansible.plugins.callback import CallbackBase  # noqa: F401
except ModuleNotFoundError:
    ansible = types.ModuleType("ansible")
    plugins = types.ModuleType("ansible.plugins")
    callback = types.ModuleType("ansible.plugins.callback")

    class CallbackBase:
        def __init__(self, *args, **kwargs):
            self._display = None

    callback.CallbackBase = CallbackBase
    sys.modules["ansible"] = ansible
    sys.modules["ansible.plugins"] = plugins
    sys.modules["ansible.plugins.callback"] = callback

spec = importlib.util.spec_from_file_location("jenkins_plain", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

assert mod.format_ok_summary([]) is None
assert mod.format_ok_summary(["a"]) == "  ok: [a]"
assert mod.format_ok_summary(["a", "b"]) == "  ok: 2 hosts — a, b"
long = [f"h{i}" for i in range(10)]
line = mod.format_ok_summary(long)
assert line.startswith("  ok: 10 hosts — h0, h1, h2, h3,")
assert "(+6 more)" in line
print("OK: format_ok_summary")

assert mod.format_skipped_summary(["x"]) == "  skipped: [x]"
assert mod.format_skipped_summary(["x", "y"]) == "  skipped: 2 hosts — x, y"
print("OK: format_skipped_summary")

assert mod.format_result_message({"msg": "line one\nline two"}) == "line one line two"
bounded = mod.format_result_message({"payload": "x" * 500}, max_chars=100)
assert len(bounded) == 100
assert bounded.endswith("...")
assert mod.format_result_message({"msg": {"b": 2, "a": 1}}) == '{"a": 1, "b": 2}'
print("OK: format_result_message")

import os

os.environ["JENKINS_ANSIBLE_VERBOSE_OUTPUT"] = "1"
cb2 = mod.CallbackModule()
lines = []

class CaptureDisplay:
    def display(self, msg, color=None, **kwargs):
        lines.append(msg)

cb2._display = CaptureDisplay()
host = type("H", (), {"get_name": lambda self: "worker1"})()
result = type("R", (), {"_host": host, "_result": {"changed": False}})()
cb2.v2_runner_on_ok(result)
assert lines == ["  ok: [worker1]"]
os.environ.pop("JENKINS_ANSIBLE_VERBOSE_OUTPUT", None)
print("OK: verbose per-host ok")

# _line must not pass invalid display colors (breaks when Ansible display is wired to logging).
from unittest.mock import MagicMock

class FakeDisplay:
    def display(self, msg, color=None, **kwargs):
        if color is not None and color not in ("red", "green", "yellow", "cyan", "blue", "magenta", "white", "bright red", "bright green"):
            raise AssertionError(f"Invalid color supplied to display: {color}")

cb = mod.CallbackModule()
cb._display = FakeDisplay()
cb._line("plain")
cb._line("")
print("OK: _line display color")

lines = []
cb._display = CaptureDisplay()
failed = type(
    "R",
    (),
    {"_host": host, "_result": {"msg": "first line\n" + ("x" * 2000)}},
)()
cb.v2_runner_on_failed(failed)
assert lines[0] == ""
assert lines[1].startswith("  ** FAILED: [worker1] => first line ")
assert len(lines[1]) < 1300
assert lines[1].endswith("...")
print("OK: bounded failure output")

license_tasks = (
    root / "ansible-playbooks/roles/cm_install/tasks/configure_cm_license.yml"
).read_text()
parcel_tasks = (
    root / "ansible-playbooks/common_tasks/activate_cluster_parcels.yml"
).read_text()
ranger_tasks = (
    root
    / "ansible-playbooks/roles/cdh_base_cluster/tasks/reconcile_ranger_stale_config.yml"
).read_text()
ecs_install_tasks = (
    root / "ansible-playbooks/roles/ecs/tasks/ecs_install_control_plane.yml"
).read_text()
assert "var: license_upload_response" not in license_tasks
assert "cluster_parcels_activation_failure_summary" in parcel_tasks
assert "to_nice_json" not in parcel_tasks
assert "base_cluster_ranger_stale_roles | to_json" not in ranger_tasks
assert "default(ecs_control_plane_install)" not in ecs_install_tasks
print("OK: concise phase output contracts")
PY

echo "OK: jenkins_plain callback helpers"
