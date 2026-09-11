#!/usr/bin/env bash
# Unified console output: quiet | normal | verbose
# Auto: Jenkins/CI -> quiet; interactive TTY -> normal; else quiet.
# Standalone: OUTPUT_MODE=verbose or VERBOSE=true

output_mode() {
  local mode="${OUTPUT_MODE:-}"
  case "${mode,,}" in
    quiet|normal|verbose) printf '%s' "${mode,,}"; return 0 ;;
  esac
  if [[ "${VERBOSE:-}" == "1" || "${VERBOSE:-}" == "true" ]]; then
    printf 'verbose'
    return 0
  fi
  if [[ -n "${BUILD_NUMBER:-}" || "${CI:-}" == "true" || "${JENKINS_URL:-}" != "" ]]; then
    printf 'quiet'
    return 0
  fi
  if [[ -t 1 ]]; then
    printf 'normal'
    return 0
  fi
  printf 'quiet'
}

output_is_quiet() {
  [[ "$(output_mode)" == "quiet" ]]
}

output_is_normal() {
  [[ "$(output_mode)" == "normal" ]]
}

output_is_verbose() {
  [[ "$(output_mode)" == "verbose" ]]
}

# Terraform plan: quiet unless SHOW_TF_PLAN_OUTPUT or verbose.
output_show_tf_plan() {
  case "${SHOW_TF_PLAN_OUTPUT:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
  esac
  output_is_verbose
}

# Terraform init/apply detail logs (always written in quiet mode).
output_log_dir() {
  printf '%s' "${LOG_DIR:-${REPO_ROOT:-.}/jenkins/artifacts}"
}

output_terraform_init_log() {
  printf '%s/terraform-init-%s.log' "$(output_log_dir)" "${BUILD_NUMBER:-local}"
}

output_terraform_apply_log() {
  printf '%s/terraform-apply-%s.log' "$(output_log_dir)" "${BUILD_NUMBER:-local}"
}

# Apply: stream resource changes; suppress huge Outputs block in quiet mode.
output_filter_terraform_apply_stream() {
  awk '
    BEGIN { in_outputs = 0 }
    /^Outputs:/ { in_outputs = 1; next }
    in_outputs { next }
    { print }
  '
}

ansible_configure_output_mode() {
  if output_is_verbose; then
    return 0
  fi
  if output_is_quiet; then
    export ANSIBLE_DISPLAY_OK_HOSTS="${ANSIBLE_DISPLAY_OK_HOSTS:-false}"
    export ANSIBLE_DISPLAY_SKIPPED_HOSTS="${ANSIBLE_DISPLAY_SKIPPED_HOSTS:-false}"
    export ANSIBLE_DISPLAY_FAILED_STDERR="${ANSIBLE_DISPLAY_FAILED_STDERR:-true}"
    export ANSIBLE_DEPRECATION_WARNINGS="${ANSIBLE_DEPRECATION_WARNINGS:-false}"
    export ANSIBLE_STDOUT_CALLBACK="${ANSIBLE_STDOUT_CALLBACK:-ansible.builtin.dense}"
  fi
}

# Stage boundary — always printed (one line).
log_milestone() {
  printf '▶ %s\n' "$*"
}

# Routine detail — suppressed in quiet; shown in normal/verbose.
log_detail() {
  output_is_quiet && return 0
  printf '%s\n' "$*"
}

# Detail only when verbose.
log_verbose() {
  output_is_verbose || return 0
  printf '%s\n' "$*"
}

# Jenkins helpers: routine messages go to LOG_FILE only in quiet mode.
log_tagged() {
  local tag="$1"
  shift
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '[%s] %s\n' "$tag" "$*" >>"$LOG_FILE"
  fi
  if ! output_is_quiet; then
    printf '[%s] %s\n' "$tag" "$*"
  fi
}

log_tagged_always() {
  local tag="$1"
  shift
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '[%s] %s\n' "$tag" "$*" | tee -a "$LOG_FILE"
  else
    printf '[%s] %s\n' "$tag" "$*"
  fi
}
