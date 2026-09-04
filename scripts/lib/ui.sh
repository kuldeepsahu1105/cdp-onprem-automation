#!/usr/bin/env bash
# Terminal UI helpers for wrapper scripts (colors + emojis when stdout is a TTY).

UI_STEP_NUM=0
UI_WIDTH=66

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

ui_rule() {
  local char="${1:-─}"
  local width="${2:-$UI_WIDTH}"
  printf "  "
  ui_c "2" "$(ui_repeat_char "$char" "$width")"
  echo ""
}

ui_banner() {
  local title="$1"
  local subtitle="${2:-}"
  local bar
  bar="$(ui_repeat_char '─' "$UI_WIDTH")"

  echo ""
  ui_c "1;36" "  ╭${bar}╮"
  printf "  │  🏗️  %-58s│\n" "$title"
  if [[ -n "$subtitle" ]]; then
    printf "  │     %-58s│\n" "$(ui_c "2" "$subtitle")"
  fi
  ui_c "1;36" "  ╰${bar}╯"
  echo ""
}

ui_section() {
  local title="$1"
  local emoji="${2:-📌}"
  UI_STEP_NUM=0
  echo ""
  ui_rule "═"
  printf "  %s  " "$emoji"
  ui_c "1;34" "$title"
  echo ""
  ui_rule "─"
}

ui_subsection() {
  local title="$1"
  local emoji="${2:-•}"
  echo ""
  printf "    %s  " "$emoji"
  ui_c "1;35" "$title"
  echo ""
}

ui_step() {
  local msg="$1"
  local emoji="${2:-▸}"
  UI_STEP_NUM=$((UI_STEP_NUM + 1))
  echo ""
  printf "    %s  " "$emoji"
  ui_c "1" "Step ${UI_STEP_NUM}"
  printf ": %s\n" "$(ui_c "0;1" "$msg")"
}

ui_ok() {
  printf "         ✅  "
  ui_c "32" "$*"
  echo ""
}

ui_info() {
  printf "    💡  "
  ui_c "36" "$*"
  echo ""
}

ui_warn() {
  printf "    ⚠️   " >&2
  ui_c "33" "$*" >&2
  echo "" >&2
}

ui_err() {
  printf "    ❌  " >&2
  ui_c "31" "$*" >&2
  echo "" >&2
}

ui_kv() {
  local key="$1"
  local value="$2"
  local emoji="${3:-  }"
  printf "    %-2s %-24s %s\n" "$emoji" "$(ui_c "2" "${key}:")" "$value"
}

ui_panel() {
  local title="${1:-}"
  shift || true
  local bar
  bar="$(ui_repeat_char '─' "$((UI_WIDTH - 4))")"

  echo ""
  if [[ -n "$title" ]]; then
    printf "  ┌─ %s " "$title"
    ui_c "2" "%s" "$(ui_repeat_char '─' "$((UI_WIDTH - ${#title} - 6))")"
    echo "┐"
  else
    ui_c "2" "  ┌${bar}┐"
    echo ""
  fi
  while [[ $# -gt 0 ]]; do
    printf "  │  %s\n" "$1"
    shift
  done
  ui_c "2" "  └${bar}┘"
  echo ""
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
        for (g in count) printf "         🖥️  %-22s %d host(s)\n", g ":", count[g]
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
  echo ""
  ui_rule "═"
  printf "  🎉  "
  ui_c "1;32" "$msg"
  echo ""
  ui_rule "═"
  echo ""
}

ui_verbose() {
  [[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-}" == "true" ]]
}

ui_git_quiet() {
  ui_verbose && return 1
  return 0
}
