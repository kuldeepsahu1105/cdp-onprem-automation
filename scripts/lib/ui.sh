#!/usr/bin/env bash
# Terminal UI helpers for wrapper scripts (colors when stdout is a TTY).

UI_STEP_NUM=0

ui_is_tty() {
  [[ -t 1 ]]
}

ui_c() {
  local code="$1"
  shift
  if ui_is_tty; then
    printf '\033[%sm' "$code"
  fi
  printf '%s' "$*"
  if ui_is_tty; then
    printf '\033[0m'
  fi
}

ui_banner() {
  local title="$1"
  local subtitle="${2:-}"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  printf "║  %-64s║\n" "$title"
  if [[ -n "$subtitle" ]]; then
    printf "║  %-64s║\n" "$subtitle"
  fi
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""
}

ui_section() {
  local title="$1"
  echo ""
  ui_c "1;34" "▸ ${title}"
  ui_c "2" "  $(printf '%.0s─' {1..60})"
}

ui_step() {
  local msg="$1"
  UI_STEP_NUM=$((UI_STEP_NUM + 1))
  echo ""
  ui_c "1;35" "  Step ${UI_STEP_NUM}"
  ui_c "1" "  ${msg}"
}

ui_ok() {
  ui_c "32" "  ✓ " 
  echo "$*"
}

ui_info() {
  ui_c "36" "  → "
  echo "$*"
}

ui_warn() {
  ui_c "33" "  ⚠ "
  echo "$*" >&2
}

ui_err() {
  ui_c "31" "  ✗ "
  echo "$*" >&2
}

ui_kv() {
  local key="$1"
  local value="$2"
  printf "  %-26s %s\n" "$(ui_c "2" "${key}:")" "$value"
}

ui_config_summary() {
  ui_section "Deployment configuration"
  ui_kv "Config file" "${TFVARS_LOADED_FROM:-not set}"
  ui_kv "Environment" "${ENVIRONMENT:-—}"
  ui_kv "AWS region" "${AWS_REGION:-—}"
  ui_kv "CPU architecture" "${CPU_ARCHITECTURE:-x86_64}"
  if [[ "${CPU_ARCHITECTURE:-x86_64}" == "arm64" ]]; then
    ui_kv "Graviton remap" "${APPLY_GRAVITON_DEFAULTS:-true}"
    ui_kv "ECS on ARM64" "${ECS_DEPLOY_ON_ARM64:-false}"
  fi
  ui_kv "AMI" "${AMI_ID:-—}"
  ui_kv "CM version" "${CM_VERSION:-—}"
  case "${DRY_RUN:-${ANSIBLE_DRY_RUN:-false}}" in
    1|true|yes|TRUE|YES|on|ON) ui_kv "Dry run" "enabled (ansible --check --diff)" ;;
  esac
}

ui_inventory_summary() {
  local inventory_file="$1"
  ui_section "Inventory"
  ui_ok "Generated ${inventory_file}"
  if [[ -f "$inventory_file" ]] && command -v awk >/dev/null 2>&1; then
    awk '
      /^\[/ {
        gsub(/[\[\]]/, "", $0)
        group=$0
        next
      }
      /^[^#[:space:]]/ && group != "" {
        count[group]++
      }
      END {
        for (g in count) printf "  %-26s %d host(s)\n", g ":", count[g]
      }
    ' "$inventory_file" | sort
  fi
}

ui_next_steps() {
  ui_section "Next steps"
  ui_info "Review ansible-playbooks/inventory.ini"
  ui_info "Run: ./clone_and_run_pvc_automation.sh"
  ui_info "Or:  cd ansible-playbooks && DEPLOY_PHASE=all ./pvc_setup.sh"
}

ui_done() {
  local msg="${1:-Completed successfully}"
  echo ""
  ui_c "1;32" "  ✓ ${msg}"
  echo ""
}

ui_verbose() {
  [[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-}" == "true" ]]
}
