# Plain stdout for Jenkins console logs (no ANSI). Loaded when jenkins_prepare_log_output sets ANSIBLE_STDOUT_CALLBACK.
from __future__ import annotations

import os

from ansible.plugins.callback import CallbackBase

_TASK_RULE = "-" * 72
_PLAY_RULE = "=" * 72


def _display_ok_hosts() -> bool:
    raw = os.environ.get("ANSIBLE_DISPLAY_OK_HOSTS", "true").strip().lower()
    return raw not in ("0", "false", "no", "off")


def _display_skipped_hosts() -> bool:
    raw = os.environ.get("ANSIBLE_DISPLAY_SKIPPED_HOSTS", "true").strip().lower()
    return raw not in ("0", "false", "no", "off")


def format_host_batch_summary(label: str, hosts: list[str], max_show: int = 4) -> str | None:
    n = len(hosts)
    if n == 0:
        return None
    if n == 1:
        return f"  {label}: [{hosts[0]}]"
    if n <= max_show:
        return f"  {label}: {n} hosts — {', '.join(hosts)}"
    sample = ", ".join(hosts[:max_show])
    return f"  {label}: {n} hosts — {sample}, … (+{n - max_show} more)"


def format_ok_summary(hosts: list[str], max_show: int = 4) -> str | None:
    return format_host_batch_summary("ok", hosts, max_show=max_show)


def format_skipped_summary(hosts: list[str], max_show: int = 4) -> str | None:
    return format_host_batch_summary("skipped", hosts, max_show=max_show)


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "jenkins_plain"

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._ok_hosts: list[str] = []
        self._skipped_hosts: list[str] = []

    def _line(self, msg: str = "") -> None:
        # Do not pass color= — "none" is invalid when Ansible wires display to logging.
        self._display.display(msg)

    def _flush_ok(self) -> None:
        if not _display_ok_hosts():
            self._ok_hosts.clear()
            return
        summary = format_ok_summary(self._ok_hosts)
        self._ok_hosts.clear()
        if summary:
            self._line(summary)

    def _flush_skipped(self) -> None:
        if not _display_skipped_hosts():
            self._skipped_hosts.clear()
            return
        summary = format_skipped_summary(self._skipped_hosts)
        self._skipped_hosts.clear()
        if summary:
            self._line(summary)

    def _flush_pending_hosts(self) -> None:
        self._flush_ok()
        self._flush_skipped()

    def _task_banner(self, label: str) -> None:
        self._flush_pending_hosts()
        self._line("")
        self._line(label)
        self._line(_TASK_RULE)

    def v2_playbook_on_play_start(self, play) -> None:
        self._flush_pending_hosts()
        name = play.get_name().strip() or getattr(play, "_play_name", "play")
        self._line("")
        self._line(f"PLAY [{name}]")
        self._line(_PLAY_RULE)
        self._line("")

    def v2_playbook_on_task_start(self, task, is_conditional=False) -> None:
        self._task_banner(f"TASK [{task.get_name()}]")

    def v2_playbook_on_handler_task_start(self, task) -> None:
        self._task_banner(f"HANDLER [{task.get_name()}]")

    def v2_runner_on_ok(self, result, **kwargs) -> None:
        host = result._host.get_name()
        if result._result.get("changed", False):
            self._flush_pending_hosts()
            self._line(f"  >> changed: [{host}]")
        else:
            self._ok_hosts.append(host)

    def v2_runner_on_failed(self, result, **kwargs) -> None:
        self._flush_pending_hosts()
        host = result._host.get_name()
        msg = result._result.get("msg", result._result)
        self._line("")
        self._line(f"  ** FAILED: [{host}] => {msg}")

    def v2_runner_on_unreachable(self, result, **kwargs) -> None:
        self._flush_pending_hosts()
        host = result._host.get_name()
        msg = result._result.get("msg", result._result)
        self._line("")
        self._line(f"  ** UNREACHABLE: [{host}] => {msg}")

    def v2_runner_on_skipped(self, result, **kwargs) -> None:
        if not _display_skipped_hosts():
            return
        self._skipped_hosts.append(result._host.get_name())

    def v2_playbook_on_stats(self, stats) -> None:
        self._flush_pending_hosts()
        self._line("")
        self._line("PLAY RECAP")
        self._line(_PLAY_RULE)
        for host in sorted(stats.processed.keys()):
            s = stats.summarize(host)
            self._line(
                f"  {host}: ok={s['ok']} changed={s['changed']} unreachable={s['unreachable']} "
                f"failed={s['failures']} skipped={s['skipped']}"
            )
        self._line("")
