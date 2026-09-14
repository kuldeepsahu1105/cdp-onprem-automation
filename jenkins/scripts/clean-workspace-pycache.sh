#!/usr/bin/env bash
# Remove Ansible callback __pycache__ before git CleanBeforeCheckout (root-owned pyc blocks git clean -fdx).
# After sudo removal, restore workspace ownership so git fetch can write .git/objects.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WS="${WORKSPACE:-$REPO_ROOT}"
SUDO_USED=0

_restore_workspace_owner() {
  local run_user run_group
  [[ -d "$WS" ]] || return 0
  run_user="$(id -un)"
  run_group="$(id -gn)"
  if sudo -n chown -R "${run_user}:${run_group}" "$WS" 2>/dev/null; then
    printf '[workspace-pycache] restored workspace owner: %s:%s\n' "$run_user" "$run_group"
    return 0
  fi
  if sudo -n chown -R jenkins:jenkins "$WS" 2>/dev/null; then
    printf '[workspace-pycache] restored workspace owner: jenkins:jenkins\n'
    return 0
  fi
  printf '[workspace-pycache] WARN: could not chown workspace %s (git checkout may fail on .git/objects)\n' "$WS" >&2
  return 0
}

_git_objects_unwritable() {
  [[ -d "$WS/.git/objects" ]] || return 1
  [[ -w "$WS/.git/objects" ]] || return 0
  return 1
}

_clean_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  chmod -R u+w "$d" 2>/dev/null || true
  rm -rf "$d" 2>/dev/null && return 0
  if sudo -n rm -rf "$d" 2>/dev/null; then
    SUDO_USED=1
    printf '[workspace-pycache] removed via sudo: %s\n' "$d"
    return 0
  fi
  printf '[workspace-pycache] WARN: could not remove %s (fix on agent: sudo rm -rf %s)\n' "$d" "$d" >&2
  return 0
}

case "${1:-}" in
  --restore-workspace-owner)
    _restore_workspace_owner
    exit 0
    ;;
esac

if [[ ! -d "$WS" ]]; then
  exit 0
fi

while IFS= read -r -d '' pycache_dir; do
  _clean_dir "$pycache_dir"
done < <(find "$WS/ansible-playbooks" -type d -name __pycache__ -print0 2>/dev/null || true)

if [[ "$SUDO_USED" == 1 ]] || _git_objects_unwritable; then
  _restore_workspace_owner
fi
