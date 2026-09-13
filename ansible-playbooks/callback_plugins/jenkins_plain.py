# Plain stdout for Jenkins console logs (no ANSI). Loaded when jenkins_prepare_log_output sets ANSIBLE_STDOUT_CALLBACK.
from __future__ import annotations

from ansible.plugins.callback import CallbackBase


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "jenkins_plain"

    def _line(self, msg: str) -> None:
        self._display.display(msg, color="none")

    def v2_playbook_on_play_start(self, play) -> None:
        name = play.get_name().strip() or getattr(play, "_play_name", "play")
        self._line(f"PLAY [{name}]")

    def v2_playbook_on_task_start(self, task, is_conditional=False) -> None:
        self._line(f"TASK [{task.get_name()}]")

    def v2_runner_on_ok(self, result, **kwargs) -> None:
        host = result._host.get_name()
        if result._result.get("changed", False):
            self._line(f"  changed: [{host}]")
        else:
            self._line(f"  ok: [{host}]")

    def v2_runner_on_failed(self, result, **kwargs) -> None:
        host = result._host.get_name()
        self._line(f"  failed: [{host}] => {result._result.get('msg', result._result)}")

    def v2_runner_on_unreachable(self, result, **kwargs) -> None:
        host = result._host.get_name()
        self._line(f"  unreachable: [{host}] => {result._result.get('msg', result._result)}")

    def v2_runner_on_skipped(self, result, **kwargs) -> None:
        host = result._host.get_name()
        self._line(f"  skipped: [{host}]")

    def v2_playbook_on_stats(self, stats) -> None:
        self._line("PLAY RECAP")
        for host in sorted(stats.processed.keys()):
            s = stats.summarize(host)
            self._line(
                f"  {host}: ok={s['ok']} changed={s['changed']} unreachable={s['unreachable']} "
                f"failed={s['failures']} skipped={s['skipped']}"
            )
