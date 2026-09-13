#!/usr/bin/env bash
# Self-test: Jenkins plain console (no ANSI); artifact log matches console.
set -euo pipefail

unset NO_COLOR ANSIBLE_NOCOLOR JENKINS_ANSI_CONSOLE ANSIBLE_CI_CONSOLE

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

BUILD_NUMBER=1 JENKINS_URL=http://jenkins/ TERM=dumb JENKINS_PLAIN_LOG=1 \
  bash -c "source '$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh'; jenkins_log_pipe '$LOG' bash -c \"printf '\\\\033[32mok\\\\033[0m\\\\n'; printf 'https://example.com/cm\\\\n'\"" \
  >"$OUT" 2>&1

if grep -q $'\033' "$OUT"; then
  fail "Jenkins console must not contain ANSI escapes (got raw color codes)"
fi
grep -q '^ok$' "$OUT" || fail "console should show stripped ok line"
if grep -q $'\033' "$LOG"; then
  fail "log file must not contain ANSI"
fi
grep -q 'https://example.com/cm' "$LOG" || fail "log file should keep URL line"

BUILD_NUMBER=1 JENKINS_URL=http://jenkins/ TERM=dumb UI_COLOR=0 JENKINS_PLAIN_LOG=1 \
  bash -c "source '$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh'; jenkins_log_pipe '$TMP/header.out' bash -c \"source '$REPO_ROOT/scripts/lib/ansible_env.sh'; source '$REPO_ROOT/scripts/lib/ui.sh'; ui_phase_header 'deployment portal bootstrap'\"" \
  >"$TMP/header-console.txt" 2>&1
grep -q 'PHASE: deployment portal bootstrap' "$TMP/header-console.txt" \
  || fail "phase header text should appear on console"
grep -q $'\033' "$TMP/header-console.txt" \
  && fail "phase header must be plain (no ANSI) in Jenkins default mode"

BUILD_NUMBER=1 JENKINS_URL=http://jenkins/ TERM=dumb UI_COLOR=0 JENKINS_PLAIN_LOG=1 \
  bash -c "source '$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh'; jenkins_log_pipe '$TMP/footer.out' bash -c \"source '$REPO_ROOT/scripts/lib/ansible_env.sh'; source '$REPO_ROOT/scripts/lib/ui.sh'; ui_phase_header 'test'; ui_phase_footer 'test'\"" \
  >"$TMP/footer-console.txt" 2>&1
grep -q 'PHASE COMPLETE: test' "$TMP/footer-console.txt" \
  || fail "phase footer text should appear on console"
grep -q $'\033' "$TMP/footer-console.txt" \
  && fail "phase footer must be plain in Jenkins default mode"
! grep -q $'\033' "$TMP/header.out" \
  || fail "phase header log artifact must stay plain"

export BUILD_NUMBER=1 JENKINS_URL=http://jenkins/
export JENKINS_PLAIN_LOG=1
jenkins_prepare_log_output
ansible_configure_output
[[ "${ANSIBLE_FORCE_COLOR}" == "0" && "${PY_COLORS}" == "0" ]] \
  || fail "ansible_configure_output should disable color in Jenkins plain mode"

unset BUILD_NUMBER JENKINS_URL JENKINS_PLAIN_LOG
export ANSIBLE_FORCE_COLOR=1
ansible_configure_output
[[ "${ANSIBLE_FORCE_COLOR}" == "0" ]] \
  || fail "without TTY or Jenkins, forced color should stay off when piped"

echo "OK: jenkins plain log pipe + ansible_configure_output"
