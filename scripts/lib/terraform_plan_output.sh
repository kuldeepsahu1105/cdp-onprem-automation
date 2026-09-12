#!/usr/bin/env bash
# Terraform plan console output: silent in Jenkins by default; full plan locally.

terraform_plan_console_full() {
  case "${SHOW_TF_PLAN_OUTPUT:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
  esac
  [[ "${VERBOSE:-}" == "1" || "${VERBOSE:-}" == "true" ]] && return 0
  if [[ -t 1 && -z "${BUILD_NUMBER:-}" && -z "${JENKINS_URL:-}" && "${CI:-}" != "true" ]]; then
    return 0
  fi
  return 1
}

terraform_plan_detail_log_path() {
  local base="${LOG_DIR:-${REPO_ROOT:-.}/jenkins/artifacts}"
  printf '%s/terraform-plan-%s-detail.log' "$base" "${BUILD_NUMBER:-local}"
}

terraform_run_plan() {
  local tf_dir="${1:-.}"
  local plan_file="${2:-tfplan.out}"
  local plan_log rc

  plan_log="$(terraform_plan_detail_log_path)"
  mkdir -p "$(dirname "$plan_log")"

  if terraform_plan_console_full; then
    terraform -chdir="$tf_dir" plan "${TF_VARS[@]}" -out="$plan_file" -no-color
    return $?
  fi

  set +e
  terraform -chdir="$tf_dir" plan "${TF_VARS[@]}" -out="$plan_file" -no-color >"$plan_log" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    if declare -F ui_err >/dev/null 2>&1; then
      ui_err "Terraform plan failed (exit ${rc})"
    else
      printf '[terraform] plan FAILED (exit %s)\n' "$rc" >&2
    fi
    cat "$plan_log"
    return "$rc"
  fi

  if declare -F ui_ok >/dev/null 2>&1; then
    ui_ok "Terraform plan completed"
  else
    printf '[terraform] plan completed\n'
  fi
  return 0
}
