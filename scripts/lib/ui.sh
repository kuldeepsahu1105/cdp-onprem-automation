#!/usr/bin/env bash
# Terminal UI helpers for wrapper scripts (colors + emojis when stdout is a TTY).

UI_STEP_NUM=0
UI_WIDTH=66
UI_TAB=$'\t'

ui_is_tty() {
  [[ -t 1 ]]
}

ui_repeat_char() {
  local char="$1"
  local count="$2"
  printf '%*s' "$count" '' | tr ' ' "$char"
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

ui_nl() {
  echo ""
}

ui_rule() {
  local char="${1:-─}"
  local width="${2:-$UI_WIDTH}"
  printf "  "
  ui_c "2" "$(ui_repeat_char "$char" "$width")"
  ui_nl
}

# Tabular row: [indent][emoji\t]label\tvalue
ui_row() {
  local indent="$1"
  local emoji="$2"
  local label="$3"
  local value="${4-}"

  printf '%s' "$indent"
  if [[ -n "$emoji" ]]; then
    printf '%s%s' "$emoji" "$UI_TAB"
  fi
  if [[ -n "$label" ]]; then
    printf '%s' "$label"
  fi
  if [[ $# -ge 4 ]]; then
    printf '%s%s' "$UI_TAB" "$value"
  fi
  ui_nl
}

ui_banner() {
  local title="$1"
  local subtitle="${2:-}"

  ui_nl
  ui_rule "═"
  printf '  🏗️%s' "$UI_TAB"
  ui_c "1;36" "$title"
  ui_nl
  if [[ -n "$subtitle" ]]; then
    printf '  %s' "$UI_TAB"
    ui_c "2" "$subtitle"
    ui_nl
  fi
  ui_rule "═"
  ui_nl
}

ui_section() {
  local title="$1"
  local emoji="${2:-📌}"
  UI_STEP_NUM=0
  ui_nl
  ui_rule "═"
  printf '  %s%s' "$emoji" "$UI_TAB"
  ui_c "1;34" "$title"
  ui_nl
  ui_rule "─"
}

ui_subsection() {
  local title="$1"
  local emoji="${2:-•}"
  ui_nl
  printf '    %s%s' "$emoji" "$UI_TAB"
  ui_c "1;35" "$title"
  ui_nl
}

ui_step() {
  local msg="$1"
  local emoji="${2:-▸}"
  UI_STEP_NUM=$((UI_STEP_NUM + 1))
  ui_nl
  printf '    %s%s' "$emoji" "$UI_TAB"
  ui_c "1" "Step ${UI_STEP_NUM}:"
  printf '%s' "$UI_TAB"
  ui_c "0;1" "$msg"
  ui_nl
}

ui_ok() {
  printf '    %s✅%s' "$UI_TAB" "$UI_TAB"
  ui_c "32" "$*"
  ui_nl
}

ui_info() {
  printf '    💡%s' "$UI_TAB"
  ui_c "36" "$*"
  ui_nl
}

ui_warn() {
  printf '    ⚠️%s' "$UI_TAB" >&2
  ui_c "33" "$*" >&2
  ui_nl >&2
}

ui_err() {
  printf '    ❌%s' "$UI_TAB" >&2
  ui_c "31" "$*" >&2
  ui_nl >&2
}

ui_kv() {
  local key="$1"
  local value="$2"
  local emoji="${3:-}"
  printf '    '
  if [[ -n "$emoji" ]]; then
    printf '%s%s' "$emoji" "$UI_TAB"
  fi
  ui_c "2" "${key}:"
  printf '%s%s\n' "$UI_TAB" "$value"
}

ui_config_summary() {
  ui_section "Deployment configuration" "📋"
  ui_kv "Config file" "${TFVARS_LOADED_FROM:-not set}" "📄"
  ui_kv "Environment" "${ENVIRONMENT:-—}" "🌍"
  ui_kv "AWS region" "${AWS_REGION:-—}" "📍"
  ui_kv "CPU architecture" "${CPU_ARCHITECTURE:-x86_64}" "🖥️"
  if [[ "${CPU_ARCHITECTURE:-x86_64}" == "arm64" ]]; then
    ui_kv "Graviton remap" "${APPLY_GRAVITON_DEFAULTS:-true}" "⚡"
    ui_kv "ECS on ARM64" "${ECS_DEPLOY_ON_ARM64:-false}" "📦"
  fi
  ui_kv "AMI" "${AMI_ID:-—}" "💿"
  ui_kv "CM version" "${CM_VERSION:-—}" "🔖"
  case "${DRY_RUN:-${ANSIBLE_DRY_RUN:-false}}" in
    1|true|yes|TRUE|YES|on|ON) ui_kv "Dry run" "enabled (no changes applied)" "🧪" ;;
    *) ui_kv "Dry run" "disabled" "▶️" ;;
  esac
}

ui_inventory_summary() {
  local inventory_file="$1"
  ui_subsection "Host groups" "📊"
  if [[ -f "$inventory_file" ]] && command -v awk >/dev/null 2>&1; then
    awk -v tab="$UI_TAB" '
      /^\[/ {
        gsub(/[\[\]]/, "", $0)
        group=$0
        next
      }
      /^[^#[:space:]]/ && group != "" {
        count[group]++
      }
      END {
        for (g in count) printf "         🖥️%s%s%s%d host(s)\n", tab, g ":", tab, count[g]
      }
    ' "$inventory_file" | sort
  fi
}

ui_next_steps() {
  ui_section "Next steps" "🚀"
  ui_info "Review ansible-playbooks/inventory.ini"
  ui_info "Run: ./clone_and_run_pvc_automation.sh"
  ui_info "Or:  cd ansible-playbooks && DEPLOY_PHASE=all ./pvc_setup.sh"
}

ui_done() {
  local msg="${1:-Completed successfully}"
  ui_nl
  ui_rule "═"
  printf '  🎉%s' "$UI_TAB"
  ui_c "1;32" "$msg"
  ui_nl
  ui_rule "═"
  ui_nl
}

ui_verbose() {
  [[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-}" == "true" ]]
}

ui_git_quiet() {
  ui_verbose && return 1
  return 0
}
