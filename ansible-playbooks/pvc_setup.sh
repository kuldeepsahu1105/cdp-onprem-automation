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
# SSH key required for Ansible: *.pem or id_rsa in this dir, ~/.ssh/id_rsa, or ANSIBLE_PRIVATE_KEY
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
# shellcheck source=../scripts/lib/ansible_group_vars_overrides.sh
source "$REPO_ROOT/scripts/lib/ansible_group_vars_overrides.sh"
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
  DEPLOY_PHASE     1|2|3|cm_tls|cdh|portal|monitoring|ecs|6|7|4|5|all
  MONITORING_STACK_ENABLED  true|false (default true) — portal + Grafana/Prometheus bootstrap
  DEPLOYMENT_PORTAL_ENABLED true|false (default true)
  ECS_DATA_SERVICES_DEPLOY_ENABLED true|false — run 34_setup_ecs_data_services.yml (phase 5/7)
  DRY_RUN          true|false
  CONTROL_MODE     auto|local|remote
  ANSIBLE_PRIVATE_KEY  SSH key: .pem/id_rsa in ansible-playbooks/, ~/.ssh/id_rsa, or explicit path
  CM_INFO_FILE         *info.txt with archive login:/password: (phase 3)
  CM_REPO_USERNAME     Archive creds — alternative to info file or all.yml
  CM_REPO_PASSWORD     Archive creds — alternative to info file or all.yml
  CM_LICENSE_CONTENT   License file body when no *license* file on disk (Jenkins textarea)
  LICENSE_FILE         Path to license file (set by Jenkins or manually)

Run from: ansible-playbooks/ inside a git clone (needs ../scripts/lib/ui.sh)
EOF
  exit 0
fi

ensure_bash
ansible_configure_output

DEPLOY_PHASE="${DEPLOY_PHASE:-1}"
CONTROL_MODE="$(detect_control_mode "$SCRIPT_DIR/inventory.ini")"

_portal_enabled() {
  [[ "${DEPLOYMENT_PORTAL_ENABLED:-true}" == "true" || "${DEPLOYMENT_PORTAL_ENABLED:-true}" == "1" ]]
}
_monitoring_enabled() {
  [[ "${MONITORING_STACK_ENABLED:-true}" == "true" || "${MONITORING_STACK_ENABLED:-true}" == "1" ]]
}

ARCH_ANSIBLE_ARGS=()
if [[ "${CPU_ARCHITECTURE:-x86_64}" == "arm64" ]]; then
  ARCH_ANSIBLE_ARGS+=(-e "target_cpu_architecture=arm64")
  ARCH_ANSIBLE_ARGS+=(-e "ecs_deploy_on_arm64=${ECS_DEPLOY_ON_ARM64:-false}")
fi
if [[ "$CONTROL_MODE" == "local" ]]; then
  ARCH_ANSIBLE_ARGS+=(-e "ansible_user=root")
fi
ARCH_ANSIBLE_ARGS+=(-e "ansible_control_mode=${CONTROL_MODE}")

print_banner() {
  if is_dry_run; then
    ui_warn "Dry run enabled — Ansible will use --check --diff (no changes applied)."
    ui_warn "CM API playbooks (31/33) may still perform live API calls; use DEPLOY_PHASE=1-3 to limit scope."
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
  # Collections ensured at script start; skip imported 00_ensure_collections in each playbook.
  ansible-playbook "$playbook" "${ANSIBLE_PLAYBOOK_ARGS[@]}" "${ARCH_ANSIBLE_ARGS[@]}" \
    --skip-tags collections "$@"
}

cd "$SCRIPT_DIR"
apply_ansible_group_vars_overrides "$REPO_ROOT" "$SCRIPT_DIR"

if [[ "${PVC_SETUP_FROM_WRAPPER:-0}" == "1" ]]; then
  ui_subsection "Playbook execution (pvc_setup.sh)" "📜"
  if is_dry_run; then
    ui_warn "Dry run enabled — Ansible will use --check --diff (no changes applied)."
    ui_warn "CM API playbooks (31/33) may still perform live API calls; use DEPLOY_PHASE=1-3 to limit scope."
  fi
else
  wrapper_print_identity "Cloudera Private Cloud Deployment (pvc_setup.sh)" "$REPO_ROOT" "$REPO_ROOT/scripts/lib"
  ui_kv "Phase" "${DEPLOY_PHASE}" "🔢"
  ui_kv "Control mode" "${CONTROL_MODE}" "🎚"
  ui_kv "CPU" "${CPU_ARCHITECTURE:-x86_64}" "💻"
  print_banner
fi

PRIVATE_KEY="$(resolve_private_key "$SCRIPT_DIR")"
if [[ "${PVC_SETUP_FROM_WRAPPER:-0}" != "1" ]]; then
  ui_note_ssh_key_requirement
fi
ui_kv "SSH private key" "$PRIVATE_KEY" "🔑"

if ! is_dry_run; then
  patch_ansible_private_key_in_group_vars "$SCRIPT_DIR" "$PRIVATE_KEY"
fi

needs_license() {
  case "$DEPLOY_PHASE" in
    3|cm|phase3|cm_tls|cm_tls_krb_ldap|cdh|cdh_install|4|cluster|phase4|5|ecs|phase5|all|full) return 0 ;;
    *) return 1 ;;
  esac
}

if needs_license; then
  materialize_cm_license_content "$SCRIPT_DIR"
  if LICENSE_KEY="$(resolve_license_file "$SCRIPT_DIR" 2>/dev/null)"; then
    if ! is_dry_run; then
      ensure_license_txt "$SCRIPT_DIR" "$LICENSE_KEY"
    fi
    ui_kv "License file" "$LICENSE_KEY" "📜"
  else
    ui_info "No license file in ansible-playbooks/ — CM may use trial license or group_vars/all.yml"
  fi
fi

load_cm_repo_credentials "$SCRIPT_DIR" || true
if [[ -n "${CM_REPO_USERID:-}" ]]; then
  ui_kv "CM archive user" "$CM_REPO_USERID" "👤"
fi

mapfile -t ANSIBLE_PLAYBOOK_ARGS < <(ansible_extra_args "$PRIVATE_KEY")

# Same helper as 00_ensure_collections.yml / manual playbooks (no-op when already installed).
if _ansible_requirements_collections_present "$SCRIPT_DIR/requirements.yml"; then
  ui_info "Ansible collections already installed — skipping galaxy (requirements.yml)"
else
  ui_step "Install Ansible collections" "📦"
fi
ansible_install_collections_if_needed "$SCRIPT_DIR/requirements.yml"

# SSH pre-reqs: include ipaserver when that group has hosts (FreeIPA); skip for AD-only inventory
if grep -A30 '^\[ipaserver\]' "$SCRIPT_DIR/inventory.ini" | grep -qE '^[^#[:space:]]'; then
  SSH_LIMIT="${ANSIBLE_LIMIT_SSH:-all}"
else
  SSH_LIMIT="${ANSIBLE_LIMIT_SSH:-all:!ipaserver}"
fi
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

run_phase_portal() {
  _run_deployment_portal_bootstrap
}

run_phase_2() {
  run_playbook 00_detect_identity.yml
  run_playbook 11_identity_setup.yml
  _run_deployment_portal_refresh
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
    run_playbook 20_setup_cm_repos.yml "${cm_extra[@]}"
  else
    run_playbook 22_download_repos.yml "${cm_extra[@]}"
  fi
  run_playbook 23_setup_postgres.yml "${cm_extra[@]}"
  run_playbook 24_start_cm.yml "${cm_extra[@]}"
  run_playbook 25_verify_cm.yml -e ansible_become=false
  run_playbook 26_setup_cm_license.yml -e ansible_become=false
  _run_deployment_portal_refresh
}

run_phase_cm_tls() {
  run_playbook 27_setup_cm_autotls.yml
  _run_deployment_portal_refresh
  run_playbook 28_setup_cm_krbs.yml
  run_playbook 29_setup_cm_cms.yml
  run_playbook 30_setup_cm_ldap.yml
  _run_deployment_portal_refresh
}

run_phase_cdh() {
  run_playbook 31_setup_base_cluster.yml
  _run_deployment_portal_refresh
}

run_phase_monitoring() {
  if ! _monitoring_enabled; then
    ui_info "MONITORING_STACK_ENABLED=false — skipping 32_setup_monitoring_stack.yml"
    return 0
  fi
  run_playbook 32_setup_monitoring_stack.yml
  _run_deployment_portal_refresh
}

# Legacy name: phase 4 = CM security + CDH base (no ECS).
run_phase_4() {
  run_phase_cm_tls
  run_phase_cdh
}

_portal_extra_args() {
  local extra=()
  if _portal_enabled; then
    extra+=(-e deployment_portal_enabled=true)
  else
    extra+=(-e deployment_portal_enabled=false)
  fi
  if _monitoring_enabled; then
    extra+=(-e monitoring_stack_enabled=true)
  fi
  printf '%s\0' "${extra[@]}"
}

_run_deployment_portal_bootstrap() {
  if ! _portal_enabled; then
    return 0
  fi
  local portal_extra=()
  while IFS= read -r -d '' arg; do portal_extra+=("$arg"); done < <(_portal_extra_args)
  # Bootstrap Caddy/pgAdmin/index only; Grafana/Prometheus via 32 or refresh with monitoring enabled.
  portal_extra+=(-e monitoring_stack_enabled=false)
  run_playbook 10_setup_deployment_portal.yml "${portal_extra[@]}"
}

_run_deployment_portal_refresh() {
  if ! _portal_enabled; then
    return 0
  fi
  local portal_extra=()
  while IFS= read -r -d '' arg; do portal_extra+=("$arg"); done < <(_portal_extra_args)
  if run_playbook 35_refresh_deployment_portal.yml "${portal_extra[@]}"; then
    return 0
  fi
  ui_warn "Portal refresh failed — running full portal bootstrap (10)."
  _run_deployment_portal_bootstrap
}

_run_ecs_data_services() {
  if [[ "${ECS_DATA_SERVICES_DEPLOY_ENABLED:-false}" == "true" || "${ECS_DATA_SERVICES_DEPLOY_ENABLED:-false}" == "1" ]]; then
    run_playbook 34_setup_ecs_data_services.yml -e ecs_data_services_deploy_enabled=true
    _run_deployment_portal_refresh
  fi
}

run_phase_6() {
  _run_deployment_portal_refresh
}

run_phase_7() {
  _run_ecs_data_services
}

run_phase_5() {
  run_playbook 33_setup_ecs_cluster.yml
  _run_deployment_portal_refresh
  _run_ecs_data_services
}

case "$DEPLOY_PHASE" in
  1|prereq|phase1|prereqs) run_phase_1 ;;
  2|identity|phase2) run_phase_2 ;;
  3|cm|phase3|cm_install) run_phase_3 ;;
  cm_tls|cm_tls_krb_ldap|tls|krb|ldap) run_phase_cm_tls ;;
  cdh|cdh_install|cdh_base|base) run_phase_cdh ;;
  portal|deployment_portal) run_phase_portal ;;
  monitoring|monitor) run_phase_monitoring ;;
  4|cluster|phase4) run_phase_4 ;;
  5|ecs|phase5) run_phase_5 ;;
  6|portal_refresh|phase6) run_phase_6 ;;
  7|dataservices|ds|phase7) run_phase_7 ;;
  all|full)
    run_phase_1
    sleep 5
    if _portal_enabled; then
      run_phase_portal
      sleep 5
    fi
    run_phase_2
    sleep 5
    run_phase_3
    sleep 5
    run_phase_cm_tls
    sleep 5
    run_phase_cdh
    sleep 5
    if _monitoring_enabled; then
      run_phase_monitoring
      sleep 5
    fi
    run_phase_5
    ;;
  *)
    ui_err "Unknown DEPLOY_PHASE=$DEPLOY_PHASE (use 1|2|3|cm_tls|cdh|portal|monitoring|ecs|all or prereq|identity|cm_install|…)"
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
