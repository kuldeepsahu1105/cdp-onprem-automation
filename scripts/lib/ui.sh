#!/usr/bin/env bash
# Terminal UI helpers for wrapper scripts (colors + emojis when stdout is a TTY).

UI_STEP_NUM=0
UI_WIDTH=66
UI_INDENT='    '
UI_KV_LABEL_W=22

ui_is_tty() {
  [[ -t 1 ]]
}

# Jenkins and C/POSIX locales often lack UTF-8; Unicode rules/emojis show as mojibake in console logs.
ui_ascii_enabled() {
  case "${UI_ASCII:-auto}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
  esac
  if [[ -n "${JENKINS_URL:-}" || -n "${BUILD_NUMBER:-}" ]]; then
    return 0
  fi
  local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [[ "$loc" == *UTF-8* || "$loc" == *utf8* ]] && return 1
  return 0
}

ui_rule_char() {
  local requested="${1:-─}"
  if ui_ascii_enabled; then
    case "$requested" in
      ═) printf '=' ;;
      ─|━) printf '-' ;;
      *) printf '-' ;;
    esac
  else
    printf '%s' "$requested"
  fi
}

ui_plain_emoji() {
  local emoji="$1"
  local ascii="${2:-}"
  if ui_ascii_enabled; then
    printf '%s' "$ascii"
  else
    printf '%s' "$emoji"
  fi
}

# Colors only when stdout is a TTY. Jenkins stages pipe to tee (| tee log), so ANSI
# would appear as literal [32m without a TTY even with ansiColor + FORCE_COLOR=1.
ui_color_enabled() {
  case "${UI_COLOR:-${FORCE_COLOR:-auto}}" in
    0|false|no|off|never)
      ui_ci_ansi_console && return 0
      return 1
      ;;
  esac
  if ui_is_tty; then
    return 0
  fi
  ui_ci_ansi_console && return 0
  case "${UI_COLOR:-${FORCE_COLOR:-auto}}" in
    1|true|yes|on|force|always) return 0 ;;
  esac
  [[ "${CLICOLOR_FORCE:-}" == "1" ]] && return 0
  return 1
}

ui_repeat_char() {
  local char="$1"
  local count="$2"
  printf '%*s' "$count" '' | tr ' ' "$char"
}

ui_c() {
  local code="$1"
  shift
  if ui_color_enabled; then
    printf '\033[%sm' "$code"
  fi
  printf '%s' "$*"
  if ui_color_enabled; then
    printf '\033[0m'
  fi
}

ui_ci_ansi_console() {
  [[ "${ANSIBLE_CI_CONSOLE:-${JENKINS_ANSI_CONSOLE:-}}" == "1" ]] && [[ "${TERM:-}" != "dumb" ]]
}

# Phase/playbook log headers: ANSI in Jenkins console (jenkins_log_pipe + ansiColor) even when
# UI_COLOR=0 keeps other wrapper labels plain ASCII (run-ansible.sh).
ui_log_header_color_enabled() {
  case "${UI_COLOR:-${FORCE_COLOR:-auto}}" in
    0|false|no|off|never)
      ui_ci_ansi_console && return 0
      return 1
      ;;
  esac
  if ui_color_enabled; then
    return 0
  fi
  ui_ci_ansi_console
}

ui_log_c() {
  local code="$1"
  shift
  if ui_log_header_color_enabled; then
    printf '\033[%sm' "$code"
  fi
  printf '%s' "$*"
  if ui_log_header_color_enabled; then
    printf '\033[0m'
  fi
}

ui_phase_header() {
  local phase="$1"
  ui_nl
  ui_rule "═"
  printf '  '
  ui_log_c "1;33" "PHASE: ${phase}"
  ui_nl
  ui_rule "═"
  ui_nl
}

ui_playbook_header() {
  local playbook="$1"
  local kind="${2:-start}"
  ui_nl
  if [[ "$kind" == "end" ]]; then
    printf '  '
    ui_log_c "1;32" "PLAYBOOK DONE: ${playbook}"
  else
    ui_rule "─"
    printf '  '
    ui_log_c "1;36" "PLAYBOOK: ${playbook}"
    ui_nl
    ui_rule "─"
  fi
  ui_nl
}

ui_nl() {
  echo ""
}

ui_rule() {
  local char
  char="$(ui_rule_char "${1:-─}")"
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
  ui_c "1;35" "$(ui_plain_emoji '🏗️  ' '[*] ')"
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
  printf '  %s  ' "$(ui_plain_emoji "$emoji" '*')"
  ui_c "1;34" "$title"
  ui_nl
  ui_rule "─"
}

ui_subsection() {
  local title="$1"
  local emoji="${2:-•}"
  ui_nl
  printf '%s%s  ' "$UI_INDENT" "$(ui_plain_emoji "$emoji" '-')"
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
  printf ' %s  ' "$(ui_plain_emoji "$emoji" '>')"
  ui_c "1" "$msg"
  ui_nl
}

ui_ok() {
  printf '%s  ' "$UI_INDENT"
  ui_c "32" "$(ui_plain_emoji '✅' 'OK')"
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
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local group="${line%%:*}"
      local count="${line##*: }"
      ui_kv "$group" "${count} host(s)" "💻"
    done < <(awk -v label_w="$UI_KV_LABEL_W" '
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
          printf "%s: %d host(s)\n", g, count[g]
        }
      }
    ' "$inventory_file" | LC_ALL=C sort)
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
