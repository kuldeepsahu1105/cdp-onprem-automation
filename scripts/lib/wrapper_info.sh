#!/usr/bin/env bash
# Shared help, version, and re-exec helpers for top-level wrapper scripts.

wrapper_git_version() {
  local root="${1:-.}"
  if git -C "$root" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "$root" rev-parse --short HEAD 2>/dev/null
  else
    printf 'unknown'
  fi
}

wrapper_has_ui() {
  declare -F ui_banner >/dev/null 2>&1
}

wrapper_dry_run_label() {
  case "${DRY_RUN:-false}" in
    1|true|yes|TRUE|YES|on|ON) printf 'enabled 🧪' ;;
    *) printf 'disabled ▶' ;;
  esac
}

wrapper_print_identity() {
  local script_name="$1"
  local repo_root="${2:-}"
  local scripts_lib="${3:-}"

  local version="unknown"
  if [[ -n "$repo_root" && -d "$repo_root/.git" ]]; then
    version="$(wrapper_git_version "$repo_root")"
  elif [[ -n "$scripts_lib" ]]; then
    version="$(wrapper_git_version "$(cd "$scripts_lib/../.." && pwd)")"
  fi

  if wrapper_has_ui; then
    ui_banner "$script_name" "git ${version} · DRY_RUN=$(wrapper_dry_run_label)"
    ui_kv "Repository" "${repo_root:-${scripts_lib:-not found}}" "📂"
    ui_kv "Dry run" "$(wrapper_dry_run_label)" "🧪"
  else
    echo ""
    echo "=== ${script_name} (version ${version}) ==="
    echo "DRY_RUN=${DRY_RUN:-false}  |  set DRY_RUN=true or pass --dry-run"
    echo "Scripts: ${scripts_lib:-not found}"
    echo ""
  fi
}

wrapper_parse_common_args() {
  WRAPPER_REMAINING_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        WRAPPER_SHOW_HELP=true
        ;;
      --dry-run|-n)
        export DRY_RUN=true
        ;;
      *)
        WRAPPER_REMAINING_ARGS+=("$arg")
        ;;
    esac
  done
}

wrapper_show_help_ansible() {
  cat <<'EOF'
Cloudera PVC Ansible wrapper

Usage:
  ./clone_and_run_pvc_automation.sh [options]
  DRY_RUN=true DEPLOY_PHASE=1 ./clone_and_run_pvc_automation.sh

Options:
  --dry-run, -n    Ansible check mode (--check --diff), no changes applied
  --help, -h       Show this help

Environment:
  DEPLOY_PHASE     1|2|3|4|5|all (default: 1)
  DRY_RUN          true|false — same as --dry-run
  CONTROL_MODE     auto|local|remote
  TFVARS_FILE      Path to .tfvars.env or .tfvars.yaml
  ANSIBLE_PRIVATE_KEY  SSH private key for Ansible (see below)
  CM_INFO_FILE         Path to *info.txt with archive login:/password:
  CM_REPO_USERNAME     Archive credentials (alternative to info file / all.yml)
  CM_REPO_PASSWORD     Archive credentials (alternative to info file / all.yml)

SSH private key (required for Ansible execution):
  • ansible-playbooks/*.pem   (e.g. from Terraform)
  • ansible-playbooks/id_rsa
  • ~/.ssh/id_rsa
  • ANSIBLE_PRIVATE_KEY=/path/to/key

CM archive credentials (phase 3 — use ONE source only):
  • ansible-playbooks/*info.txt   login: / password: lines
  • CM_REPO_USERNAME + CM_REPO_PASSWORD
  • cm_repo_username / cm_repo_password in group_vars/all.yml
  (info file or env vars override all.yml; no need for all three)

Run from:
  • Git repo root:  /path/to/cdp-onprem-automation/
  • Deployment dir: same folder as .tfvars.env (wrapper re-execs into cloned repo)

Direct (repo root only):
  cd ansible-playbooks && DRY_RUN=true DEPLOY_PHASE=1 ./pvc_setup.sh

Verify version:
  test -f scripts/lib/ui.sh && git rev-parse --short HEAD
EOF
}

wrapper_show_help_terraform() {
  cat <<'EOF'
Cloudera PVC Terraform wrapper

Usage:
  ./clone_and_run_terraform.sh [options]
  DRY_RUN=true ./clone_and_run_terraform.sh

Options:
  --dry-run, -n    terraform plan only (no apply, no inventory copy)
  --help, -h       Show this help

Environment:
  DRY_RUN          true|false — same as --dry-run
  TFVARS_FILE      Path to .tfvars.env or .tfvars.yaml

Run from git repo root or deployment dir (with .tfvars next to wrapper).

Verify version:
  test -f scripts/lib/ui.sh && git rev-parse --short HEAD
EOF
}

# If a nested git clone exists and this script is an older copy outside it, re-exec the repo script.
wrapper_reexec_from_repo_if_needed() {
  local script_dir="$1"
  local self_script="$2"
  local script_name="$3"
  shift 3

  if [[ -f "$script_dir/scripts/lib/wrapper_info.sh" ]]; then
    return 0
  fi

  local nested="$script_dir/cdp-onprem-automation"
  local repo_script="$nested/$script_name"

  if [[ ! -f "$repo_script" ]]; then
    return 0
  fi

  local self_path repo_path
  self_path="$(cd "$(dirname "$self_script")" && pwd)/$(basename "$self_script")"
  repo_path="$(cd "$nested" && pwd)/$script_name"

  if [[ "$self_path" == "$repo_path" ]]; then
    return 0
  fi

  if wrapper_has_ui; then
    ui_info "Re-exec from cloned repo: $repo_path"
  else
    echo "Re-exec from cloned repo: $repo_path"
  fi

  exec env \
    DRY_RUN="${DRY_RUN:-false}" \
    DEPLOY_PHASE="${DEPLOY_PHASE:-}" \
    CONTROL_MODE="${CONTROL_MODE:-}" \
    TFVARS_FILE="${TFVARS_FILE:-}" \
    VERBOSE="${VERBOSE:-}" \
    "$repo_path" "$@"
}
