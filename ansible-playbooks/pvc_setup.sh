#!/usr/bin/env bash
# Cloudera CDP on-prem deployment driver.
# Works from Mac or Linux, remote laptop or cluster node (cldr-mngr / ipaserver).
#
# Usage:
#   DEPLOY_PHASE=1 ./pvc_setup.sh          # prerequisites only (default)
#   DEPLOY_PHASE=2 ./pvc_setup.sh          # identity (FreeIPA or AD auto-detect)
#   DEPLOY_PHASE=3 ./pvc_setup.sh          # CM install
#   DEPLOY_PHASE=all ./pvc_setup.sh        # full flow
#   CONTROL_MODE=local ./pvc_setup.sh      # running on a host in inventory.ini
#   ANSIBLE_PRIVATE_KEY=~/.ssh/id_rsa ./pvc_setup.sh
#   DRY_RUN=true ./pvc_setup.sh            # ansible --check --diff (no changes applied)
#   ./pvc_setup.sh --dry-run               # same as DRY_RUN=true
#   ./pvc_setup.sh --help                  # usage

set -euo pipefail

WRAPPER_SHOW_HELP=false
for arg in "$@"; do
  case "$arg" in
    --help|-h) WRAPPER_SHOW_HELP=true ;;
    --dry-run|-n) export DRY_RUN=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/portable.sh
source "$REPO_ROOT/scripts/lib/portable.sh"
# shellcheck source=../scripts/lib/ansible_env.sh
source "$REPO_ROOT/scripts/lib/ansible_env.sh"
# shellcheck source=../scripts/lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"
# shellcheck source=../scripts/lib/wrapper_info.sh
source "$REPO_ROOT/scripts/lib/wrapper_info.sh"

if [[ "${WRAPPER_SHOW_HELP:-false}" == "true" ]]; then
  cat <<'EOF'
pvc_setup.sh — Cloudera PVC Ansible deployment driver

Usage:
  DEPLOY_PHASE=1 ./pvc_setup.sh
  DRY_RUN=true DEPLOY_PHASE=1 ./pvc_setup.sh
  ./pvc_setup.sh --dry-run

Options:
  --dry-run, -n    Ansible --check --diff (no changes)
  --help, -h       Show this help

Environment:
  DEPLOY_PHASE     1|2|3|4|5|all
  DRY_RUN          true|false
  CONTROL_MODE     auto|local|remote

Run from: ansible-playbooks/ inside a git clone (needs ../scripts/lib/ui.sh)
EOF
  exit 0
fi

ensure_bash

DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
CONTROL_MODE="$(detect_control_mode "$SCRIPT_DIR/inventory.ini")"

ARCH_ANSIBLE_ARGS=()
if [[ "${CPU_ARCHITECTURE:-x86_64}" == "arm64" ]]; then
  ARCH_ANSIBLE_ARGS+=(-e "target_cpu_architecture=arm64")
  ARCH_ANSIBLE_ARGS+=(-e "ecs_deploy_on_arm64=${ECS_DEPLOY_ON_ARM64:-false}")
fi

print_banner() {
  if is_dry_run; then
    ui_warn "Dry run enabled — Ansible will use --check --diff (no changes applied)."
    ui_warn "CM API playbooks (26/27) may still perform live API calls; use DEPLOY_PHASE=1-3 to limit scope."
  fi
}

run_playbook() {
  local playbook="$1"
  shift || true
  if is_dry_run; then
    ui_step "Dry-run ${playbook}" "🧪"
  else
    ui_step "Running ${playbook}" "📜"
  fi
  ansible-playbook "$playbook" "${ANSIBLE_PLAYBOOK_ARGS[@]}" "${ARCH_ANSIBLE_ARGS[@]}" "$@"
}

print_message() {
  ui_section "$1" "🔧"
}

cd "$SCRIPT_DIR"

if [[ "${PVC_SETUP_FROM_WRAPPER:-0}" == "1" ]]; then
  ui_subsection "Playbook execution (pvc_setup.sh)" "📜"
  if is_dry_run; then
    ui_warn "Dry run enabled — Ansible will use --check --diff (no changes applied)."
    ui_warn "CM API playbooks (26/27) may still perform live API calls; use DEPLOY_PHASE=1-3 to limit scope."
  fi
else
  wrapper_print_identity "Cloudera Private Cloud Deployment (pvc_setup.sh)" "$REPO_ROOT" "$REPO_ROOT/scripts/lib"
  ui_kv "Phase" "${DEPLOY_PHASE}" "🔢"
  ui_kv "Control mode" "${CONTROL_MODE}" "🎛️"
  ui_kv "CPU" "${CPU_ARCHITECTURE:-x86_64}" "🖥️"
  print_banner
fi

PRIVATE_KEY="$(resolve_private_key "$SCRIPT_DIR")"
ui_kv "SSH private key" "$PRIVATE_KEY" "🔑"

if ! is_dry_run; then
  patch_ansible_private_key_in_group_vars "$SCRIPT_DIR" "$PRIVATE_KEY"
fi

needs_license() {
  case "$DEPLOY_PHASE" in
    3|cm|phase3|4|cluster|phase4|all|full) return 0 ;;
    *) return 1 ;;
  esac
}

if needs_license; then
  LICENSE_KEY="$(resolve_license_file "$SCRIPT_DIR")"
  if ! is_dry_run; then
    ensure_license_txt "$SCRIPT_DIR" "$LICENSE_KEY"
  fi
  ui_kv "License file" "$LICENSE_KEY" "📜"
fi

load_cm_repo_credentials "$SCRIPT_DIR" || true
if [[ -n "${CM_REPO_USERID:-}" ]]; then
  ui_kv "CM archive user" "$CM_REPO_USERID" "👤"
fi

mapfile -t ANSIBLE_PLAYBOOK_ARGS < <(ansible_extra_args "$PRIVATE_KEY")

ui_step "Install Ansible collections" "📦"
ansible-galaxy collection install -r requirements.yml

# SSH pre-reqs: skip ipaserver for AD; include all for FreeIPA if ipaserver is a managed node
SSH_LIMIT="${ANSIBLE_LIMIT_SSH:-all:!ipaserver}"
ui_section "SSH prerequisites" "🔐"
ui_kv "Limit" "$SSH_LIMIT" "🎯"
ui_step "Running 00_setup_ssh_preqs.yml" "📜"
ansible-playbook 00_setup_ssh_preqs.yml "${ANSIBLE_PLAYBOOK_ARGS[@]}" --limit "$SSH_LIMIT"

run_phase_1() {
  run_playbook 01_install_collection.yml
  run_playbook 02_set_hostname.yml
  run_playbook 03_create_etc_hosts.yml
  run_playbook 05_disable_selinux.yml
  run_playbook 06_prereq_setup.yml
  run_playbook 07_prereq_setup_002.yml
  run_playbook 08_prereq_setup_003.yml
  run_playbook 09_verify_os_prereqs.yml
}

run_phase_2() {
  run_playbook 00_detect_identity.yml
  run_playbook 10_identity_setup.yml
}

run_phase_3() {
  local cm_user="${CM_REPO_USERID:-${CM_REPO_USERNAME:-}}"
  local cm_pass="${CM_REPO_PASSWD:-${CM_REPO_PASSWORD:-}}"
  local cm_extra=()
  local cm_repo_source="${CM_REPO_SOURCE:-public}"
  if [[ -f group_vars/all.yml ]]; then
    cm_repo_source="$(awk -F': *' '/^cm_repo_source:/ {gsub(/["'\'']/, "", $2); print $2; exit}' group_vars/all.yml)"
    cm_repo_source="${cm_repo_source:-public}"
  fi
  if [[ -n "$cm_user" && -n "$cm_pass" ]]; then
    cm_extra=(-e "cm_repo_username=$cm_user" -e "cm_repo_password=$cm_pass")
  fi
  if [[ "$cm_repo_source" == "internal" ]]; then
    run_playbook 16_setup_cm_repos.yml "${cm_extra[@]}"
  else
    run_playbook 17_download_repos.yml "${cm_extra[@]}"
  fi
  run_playbook 18_setup_postgres.yml "${cm_extra[@]}"
  run_playbook 19_start_cm.yml "${cm_extra[@]}"
  run_playbook 20_verify_cm.yml -e ansible_become=false
  run_playbook 21_setup_cm_license.yml -e ansible_become=false
}

run_phase_4() {
  run_playbook 22_setup_cm_autotls.yml
  run_playbook 23_setup_cm_krbs.yml
  run_playbook 24_setup_cm_cms.yml
  run_playbook 25_setup_cm_ldap.yml
  run_playbook 26_setup_base_cluster.yml
  run_playbook 27_setup_ecs_cluster.yml
}

run_phase_5() {
  run_playbook 27_setup_ecs_cluster.yml
}

case "$DEPLOY_PHASE" in
  1|prereq|phase1) run_phase_1 ;;
  2|identity|phase2) run_phase_2 ;;
  3|cm|phase3) run_phase_3 ;;
  4|cluster|phase4) run_phase_4 ;;
  5|ecs|phase5) run_phase_5 ;;
  all|full)
    run_phase_1
    sleep 5
    run_phase_2
    sleep 5
    run_phase_3
    sleep 5
    run_phase_4
    ;;
  *)
    ui_err "Unknown DEPLOY_PHASE=$DEPLOY_PHASE (use 1|2|3|4|5|all or prereq|identity|cm|cluster|ecs|all)"
    exit 1
    ;;
esac

if [[ "${PVC_SETUP_FROM_WRAPPER:-}" != "1" ]]; then
  if is_dry_run; then
    ui_done "Phase ${DEPLOY_PHASE} dry run completed (no changes applied)"
  else
    ui_done "Phase ${DEPLOY_PHASE} completed successfully"
  fi
fi
