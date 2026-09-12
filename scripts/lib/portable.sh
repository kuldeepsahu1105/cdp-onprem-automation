#!/usr/bin/env bash
# Portable helpers for Linux and macOS wrapper scripts.

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

sed_inplace() {
  local file="$1"
  shift
  if is_macos; then
    sed -i '' "$@" "$file"
  else
    sed -i "$@" "$file"
  fi
}

copy_file() {
  local src="$1"
  local dest="$2"
  cp -v "$src" "$dest"
}

has_glob_match() {
  local pattern="$1"
  # shellcheck disable=SC2086
  compgen -G "$pattern" >/dev/null 2>&1
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  echo "jq is required but not installed."
  if is_macos && command -v brew >/dev/null 2>&1; then
    echo "Installing jq with Homebrew..."
    brew install jq
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing jq with apt..."
    sudo apt-get update -qq && sudo apt-get install -y jq
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "Installing jq with dnf..."
    sudo dnf install -y jq
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "Installing jq with yum..."
    sudo yum install -y jq
    return 0
  fi
  echo "Install jq and re-run (e.g. brew install jq on macOS)."
  return 1
}

ensure_bash() {
  if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script must be run with bash."
    exit 1
  fi
}
