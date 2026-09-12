#!/usr/bin/env bash
# Run a command with optional pseudo-TTY so Ansible/Terraform emit ANSI for Jenkins ansiColor,
# while still tee'ing to a log file. Plain pipe without TTY shows literal [0;32m in the console.

jenkins_log_pipe() {
  local log_file="$1"
  shift

  if [[ -z "$log_file" || "$#" -lt 1 ]]; then
    echo "jenkins_log_pipe: usage: jenkins_log_pipe <logfile> <command> [args...]" >&2
    return 2
  fi

  if [[ -n "${BUILD_NUMBER:-}${JENKINS_URL:-}" ]] && command -v script >/dev/null 2>&1; then
    export JENKINS_SCRIPT_TTY=1
    export ANSIBLE_FORCE_COLOR="${ANSIBLE_FORCE_COLOR:-1}"
    export PY_COLORS="${PY_COLORS:-1}"
    export FORCE_COLOR="${FORCE_COLOR:-1}"
    export UI_COLOR="${UI_COLOR:-1}"
    export CLICOLOR_FORCE="${CLICOLOR_FORCE:-1}"
    local cmd_quoted
    cmd_quoted="$(printf '%q ' "$@")"
    script -e -q -c "${cmd_quoted}" /dev/null 2>&1 | tee -a "$log_file"
    return "${PIPESTATUS[0]}"
  fi

  "$@" 2>&1 | tee -a "$log_file"
  return "${PIPESTATUS[0]}"
}
