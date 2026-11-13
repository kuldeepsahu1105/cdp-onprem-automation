# Plain stdout for Jenkins console logs (no ANSI). Loaded when jenkins_prepare_log_output sets ANSIBLE_STDOUT_CALLBACK.
from __future__ import annotations

import json
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


def _verbose_per_host_output() -> bool:
    raw = os.environ.get("JENKINS_ANSIBLE_VERBOSE_OUTPUT", "").strip().lower()
    return raw in ("1", "true", "yes", "on")


def _retry_max_updates() -> int:
    try:
        value = int(os.environ.get("JENKINS_ANSIBLE_RETRY_MAX_UPDATES", "6"))
    except ValueError:
        value = 6
    return max(1, value)


def retry_update_attempts(total_attempts: int, max_updates: int = 6) -> set[int]:
    retry_events = max(0, total_attempts - 1)
    max_updates = max(1, max_updates)
    if retry_events <= max_updates:
        return set(range(1, retry_events + 1))
    if max_updates == 1:
        return {retry_events}
    return {
        1 + round(index * (retry_events - 1) / (max_updates - 1))
        for index in range(max_updates)
    }


def format_result_message(
    result: dict,
    max_chars: int | None = None,
    max_lines: int | None = None,
) -> str:
    raw = result.get("msg", result)
    if isinstance(raw, (dict, list)):
        text = json.dumps(raw, sort_keys=True, default=str)
    else:
        text = str(raw)
    lines = [" ".join(line.split()) for line in text.splitlines() if line.strip()]
    if not lines:
        lines = [""]
    if max_lines is None:
        try:
            max_lines = int(os.environ.get("JENKINS_ANSIBLE_FAILURE_MAX_LINES", "6"))
        except ValueError:
            max_lines = 6
    max_lines = max(1, max_lines)
    if len(lines) > max_lines:
        omitted = len(lines) - max_lines + 1
        lines = lines[: max_lines - 1] + [f"... ({omitted} more line(s))"]
    text = "\n".join(lines)
    if max_chars is None:
        try:
            max_chars = int(os.environ.get("JENKINS_ANSIBLE_FAILURE_MAX_CHARS", "1200"))
        except ValueError:
            max_chars = 1200
    max_chars = max(80, max_chars)
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3] + "..."


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
        elif _verbose_per_host_output():
            self._flush_pending_hosts()
            self._line(f"  ok: [{host}]")
        else:
            self._ok_hosts.append(host)

    def v2_runner_on_failed(self, result, **kwargs) -> None:
        self._flush_pending_hosts()
        host = result._host.get_name()
        msg = format_result_message(result._result)
        self._line("")
        self._line(f"  ** FAILED: [{host}] => {msg}")

    def v2_runner_on_unreachable(self, result, **kwargs) -> None:
        self._flush_pending_hosts()
        host = result._host.get_name()
        msg = format_result_message(result._result)
        self._line("")
        self._line(f"  ** UNREACHABLE: [{host}] => {msg}")

    def v2_runner_retry(self, result, **kwargs) -> None:
        payload = getattr(result, "_result", None)
        if payload is None:
            payload = getattr(result, "result", {})
        attempts = int(payload.get("attempts", 1))
        total_attempts = int(payload.get("retries", attempts + 1))
        if attempts not in retry_update_attempts(total_attempts, _retry_max_updates()):
            return

        task_name = getattr(result, "task_name", None)
        task = getattr(result, "_task", None) or getattr(result, "task", None)
        if not task_name and task is not None:
            get_name = getattr(task, "get_name", None)
            task_name = get_name() if callable(get_name) else str(task)
        task_name = task_name or "task"

        try:
            host = self.host_label(result)
        except (AttributeError, TypeError):
            host_obj = getattr(result, "_host", None) or getattr(result, "host", None)
            host = host_obj.get_name() if host_obj is not None else "unknown"

        retries_left = max(0, total_attempts - attempts)
        retry_word = "retry" if retries_left == 1 else "retries"
        self._line(
            f"  retry: [{host}] {task_name} — "
            f"attempt {attempts} ({retries_left} {retry_word} left)"
        )

    def v2_runner_on_skipped(self, result, **kwargs) -> None:
        if not _display_skipped_hosts():
            return
        host = result._host.get_name()
        if _verbose_per_host_output():
            self._flush_pending_hosts()
            self._line(f"  skipped: [{host}]")
        else:
            self._skipped_hosts.append(host)

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
