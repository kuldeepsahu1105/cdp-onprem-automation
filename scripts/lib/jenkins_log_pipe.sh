#!/usr/bin/env bash
# Tee Jenkins stage output to a log file. Console may use ansiColor; artifact logs stay plain ASCII.

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

  if [[ -n "${BUILD_NUMBER:-}${JENKINS_URL:-}" ]]; then
    # Do not use `script`/pseudo-TTY: it forces ANSI into tee'd logs and breaks copy-paste URLs.
    export ANSIBLE_FORCE_COLOR="${ANSIBLE_FORCE_COLOR:-auto}"
    export FORCE_COLOR="${FORCE_COLOR:-0}"
    export UI_COLOR="${UI_COLOR:-0}"
    export PY_COLORS="${PY_COLORS:-0}"
    "$@" 2>&1 | tee >(jenkins_strip_ansi_stream >>"$log_file")
    return "${PIPESTATUS[0]}"
  fi

  "$@" 2>&1 | tee -a "$log_file"
  return "${PIPESTATUS[0]}"
}
