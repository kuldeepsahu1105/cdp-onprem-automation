#!/usr/bin/env bash
# Tee Jenkins stage output to a log file. Console may use ansiColor; artifact logs stay plain ASCII.

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ansible_env.sh
source "$_lib_dir/ansible_env.sh"

jenkins_strip_ansi_stream() {
  # CSI color sequences and OSC hyperlinks (some terminals emit these around URLs).
  sed -E \
    -e 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
    -e 's/\x1B\][^\x07]*(\x07|\x1B\\)//g'
}

jenkins_log_pipe() {
  local log_file="$1"
  shift

  if [[ -z "$log_file" || "$#" -lt 1 ]]; then
    echo "jenkins_log_pipe: usage: jenkins_log_pipe <logfile> <command> [args...]" >&2
    return 2
  fi

  unset JENKINS_SCRIPT_TTY
  : >"$log_file"

  if jenkins_ci_detected; then
    jenkins_prepare_log_output
    if jenkins_plain_log_enabled; then
      # Strip any stray ANSI from tools (Ansible, terraform, pip) so the console never shows [1;33m garbage.
      "$@" 2>&1 | jenkins_strip_ansi_stream | tee -a "$log_file"
      return "${PIPESTATUS[0]}"
    fi
    # Opt-in ansiColor: color on console; artifact log stays plain ASCII.
    case "${ANSIBLE_FORCE_COLOR:-auto}" in
      0|false|no|off) ;;
      *)
        export ANSIBLE_FORCE_COLOR=1
        export PY_COLORS=1
        ;;
    esac
    "$@" 2>&1 | tee >(jenkins_strip_ansi_stream >>"$log_file")
    return "${PIPESTATUS[0]}"
  fi

  "$@" 2>&1 | tee -a "$log_file"
  return "${PIPESTATUS[0]}"
}
