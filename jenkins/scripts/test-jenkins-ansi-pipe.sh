#!/usr/bin/env bash
# Self-test: Jenkins console gets ANSI; artifact log file stays plain (jenkins_log_pipe).
set -euo pipefail

unset NO_COLOR ANSIBLE_NOCOLOR

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=scripts/lib/jenkins_log_pipe.sh
source "$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh"
# shellcheck source=scripts/lib/ansible_env.sh
source "$REPO_ROOT/scripts/lib/ansible_env.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/stage.log"
OUT="$TMP/stdout.capture"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

BUILD_NUMBER=1 JENKINS_URL=http://jenkins/ TERM=xterm \
  bash -c "source '$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh'; jenkins_log_pipe '$LOG' bash -c \"printf '\\\\033[32mok\\\\033[0m\\\\n'; printf 'https://example.com/cm\\\\n'\"" \
  >"$OUT" 2>&1

if ! grep -q $'\033' "$OUT"; then
  fail "stdout should contain ANSI escape"
fi
if grep -q $'\033' "$LOG"; then
  fail "log file must not contain ANSI"
fi
grep -q 'https://example.com/cm' "$LOG" || fail "log file should keep URL line"

unset NO_COLOR ANSIBLE_NOCOLOR
export JENKINS_ANSI_CONSOLE=1
export ANSIBLE_FORCE_COLOR=1
export TERM=xterm
ansible_configure_output
[[ "${ANSIBLE_FORCE_COLOR}" == "1" && "${PY_COLORS}" == "1" ]] \
  || fail "ansible_configure_output should enable color with JENKINS_ANSI_CONSOLE"

unset JENKINS_ANSI_CONSOLE NO_COLOR ANSIBLE_NOCOLOR
export ANSIBLE_FORCE_COLOR=1
ansible_configure_output
[[ "${ANSIBLE_FORCE_COLOR}" == "0" ]] \
  || fail "without JENKINS_ANSI_CONSOLE or TTY, forced color should stay off when piped"

echo "OK: jenkins ansi pipe + ansible_configure_output"
