#!/usr/bin/env bash
# Jenkins: optional input validation flags (driven by VALIDATION_CHECKS checkboxes).
set -euo pipefail

is_enabled() {
  case "${1:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

checks_contain() {
  local haystack="${VALIDATION_CHECKS:-}"
  local needle="$1"
  [[ ",${haystack}," == *",${needle},"* ]]
}

should_validate() {
  local flag="$1"
  local token="$2"
  if is_enabled "$flag"; then
    return 0
  fi
  if [[ -n "${VALIDATION_CHECKS:-}" ]] && checks_contain "$token"; then
    return 0
  fi
  return 1
}
