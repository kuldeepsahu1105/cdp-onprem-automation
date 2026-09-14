#!/usr/bin/env bash
# Remove Ansible callback __pycache__ before git CleanBeforeCheckout (root-owned pyc blocks git clean -fdx).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WS="${WORKSPACE:-$REPO_ROOT}"

_clean_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  chmod -R u+w "$d" 2>/dev/null || true
  rm -rf "$d" 2>/dev/null && return 0
  if sudo -n rm -rf "$d" 2>/dev/null; then
    printf '[workspace-pycache] removed via sudo: %s\n' "$d"
    return 0
  fi
  printf '[workspace-pycache] WARN: could not remove %s (fix on agent: sudo rm -rf %s)\n' "$d" "$d" >&2
  return 0
}

if [[ ! -d "$WS" ]]; then
  exit 0
fi

while IFS= read -r -d '' pycache_dir; do
  _clean_dir "$pycache_dir"
done < <(find "$WS/ansible-playbooks" -type d -name __pycache__ -print0 2>/dev/null || true)
