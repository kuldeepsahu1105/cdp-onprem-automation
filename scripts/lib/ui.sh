#!/usr/bin/env bash
# Terminal UI helpers for wrapper scripts (colors + emojis when stdout is a TTY).

UI_STEP_NUM=0
UI_WIDTH=66
UI_INDENT='    '
UI_KV_LABEL_W=22

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

ui_kv() {
  local key="$1"
  local value="$2"
  local emoji="${3:-}"
  printf '%s' "$UI_INDENT"
  [[ -n "$emoji" ]] && printf '%s  ' "$emoji"
  ui_c "36" "$(printf '%-*s' "$UI_KV_LABEL_W" "${key}:")"
  ui_c "1" "$value"
  ui_nl
}

ui_banner() {
  local title="$1"
  local subtitle="${2:-}"

  ui_nl
  ui_rule "═"
  printf '  '
  ui_c "1;35" '🏗️  '
  ui_c "1;36" "$title"
  ui_nl
  if [[ -n "$subtitle" ]]; then
    printf '      '
    ui_c "33" "$subtitle"
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
  printf '  %s  ' "$emoji"
  ui_c "1;34" "$title"
  ui_nl
  ui_rule "─"
}

ui_subsection() {
  local title="$1"
  local emoji="${2:-•}"
  ui_nl
  printf '%s%s  ' "$UI_INDENT" "$emoji"
  ui_c "1;35" "$title"
  ui_nl
}

ui_step() {
  local msg="$1"
  local emoji="${2:-▸}"
  UI_STEP_NUM=$((UI_STEP_NUM + 1))
  ui_nl
  printf '%s' "$UI_INDENT"
  ui_c "1;36" "Step ${UI_STEP_NUM}:"
  printf ' %s  ' "$emoji"
  ui_c "1" "$msg"
  ui_nl
}

ui_ok() {
  printf '%s  ' "$UI_INDENT"
  ui_c "32" '✅'
  printf '  '
  ui_c "32" "$*"
  ui_nl
}

ui_info() {
  printf '%s' "$UI_INDENT"
  ui_c "33" '💡  '
  ui_c "36" "$*"
  ui_nl
}

ui_warn() {
  {
    printf '%s' "$UI_INDENT"
    ui_c "33" "⚠️  $*"
    ui_nl
  } >&2
}

ui_err() {
  {
    printf '%s' "$UI_INDENT"
    ui_c "31" "❌  $*"
    ui_nl
  } >&2
}

ui_config_summary() {
  ui_section "Deployment configuration" "📋"
  ui_kv "Config file" "${TFVARS_LOADED_FROM:-not set}" "📄"
  ui_kv "Environment" "${ENVIRONMENT:-—}" "🌍"
  ui_kv "AWS region" "${AWS_REGION:-—}" "📍"
  ui_kv "CPU architecture" "${CPU_ARCHITECTURE:-x86_64}" "💻"
  if [[ "${CPU_ARCHITECTURE:-x86_64}" == "arm64" ]]; then
    ui_kv "Graviton remap" "${APPLY_GRAVITON_DEFAULTS:-true}" "⚡"
    ui_kv "ECS on ARM64" "${ECS_DEPLOY_ON_ARM64:-false}" "📦"
  fi
  ui_kv "AMI" "${AMI_ID:-—}" "💿"
  ui_kv "CM version" "${CM_VERSION:-—}" "🔖"
  case "${DRY_RUN:-${ANSIBLE_DRY_RUN:-false}}" in
    1|true|yes|TRUE|YES|on|ON)
      ui_kv "Dry run" "enabled (no changes applied)" "🧪"
      ;;
    *)
      ui_kv "Dry run" "disabled" "▶"
      ;;
  esac
}

ui_inventory_summary() {
  local inventory_file="$1"
  ui_subsection "Host groups" "📊"
  if [[ -f "$inventory_file" ]] && command -v awk >/dev/null 2>&1; then
    awk -v indent="$UI_INDENT" -v label_w="$UI_KV_LABEL_W" '
      /^\[/ {
        gsub(/[\[\]]/, "", $0)
        group=$0
        next
      }
      /^[^#[:space:]]/ && group != "" {
        count[group]++
      }
      END {
        for (g in count) {
          printf "%s💻  %-*s %d host(s)\n", indent, label_w, g ":", count[g]
        }
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
  printf '  '
  ui_c "1;32" "🎉  ${msg}"
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
