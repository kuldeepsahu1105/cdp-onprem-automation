#!/usr/bin/env bash
# Terraform destroy plan/apply (same TF_VARS / workspace as provision).

terraform_destroy_plan_log_path() {
  local base="${LOG_DIR:-${REPO_ROOT:-.}/jenkins/artifacts}"
  printf '%s/terraform-destroy-plan-%s-detail.log' "$base" "${BUILD_NUMBER:-local}"
}

terraform_run_destroy_plan() {
  local tf_dir="${1:-.}"
  local plan_file="${2:-tfplan.destroy.out}"
  local plan_log rc

  plan_log="$(terraform_destroy_plan_log_path)"
  mkdir -p "$(dirname "$plan_log")"

  if terraform_plan_console_full; then
    terraform -chdir="$tf_dir" plan -destroy "${TF_VARS[@]}" -out="$plan_file" -no-color
    return $?
  fi

  set +e
  terraform -chdir="$tf_dir" plan -destroy "${TF_VARS[@]}" -out="$plan_file" -no-color >"$plan_log" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    if declare -F ui_err >/dev/null 2>&1; then
      ui_err "Terraform destroy plan failed (exit ${rc})"
    else
      printf '[terraform-destroy] destroy plan FAILED (exit %s)\n' "$rc" >&2
    fi
    cat "$plan_log"
    return "$rc"
  fi

  if declare -F ui_ok >/dev/null 2>&1; then
    ui_ok "Terraform destroy plan completed"
  else
    printf '[terraform-destroy] destroy plan completed\n'
  fi
  return 0
}

terraform_require_destroy_confirm() {
  case "${DESTROY_STACK_CONFIRM:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
  esac
  if declare -F is_dry_run >/dev/null 2>&1 && is_dry_run; then
    return 0
  fi
  case "${DRY_RUN:-false}" in
    1|true|yes|TRUE|YES|on|ON) return 0 ;;
  esac
  if declare -F ui_err >/dev/null 2>&1; then
    ui_err "Refusing terraform destroy — set DESTROY_STACK_CONFIRM=true (or DRY_RUN=true for destroy plan only)"
  else
    printf '[terraform-destroy] ERROR: set DESTROY_STACK_CONFIRM=true or DRY_RUN=true\n' >&2
  fi
  return 1
}

terraform_run_destroy() {
  local tf_dir="${1:-.}"
  local plan_file="${2:-tfplan.destroy.out}"

  terraform_require_destroy_confirm || return 1

  ui_step "Terraform destroy plan" "📝"
  # shellcheck source=scripts/lib/terraform_plan_output.sh
  source "${SCRIPTS_LIB:-scripts/lib}/terraform_plan_output.sh"
  terraform_run_destroy_plan "$tf_dir" "$plan_file"

  case "${DRY_RUN:-false}" in
    1|true|yes|TRUE|YES|on|ON)
      if declare -F persist_terraform_state_from_workspace >/dev/null 2>&1; then
        persist_terraform_state_from_workspace "$tf_dir"
      fi
      ui_done "Dry run complete — destroy plan only (no destroy applied)"
      return 0
      ;;
  esac

  ui_step "Terraform destroy" "🧨"
  terraform -chdir="$tf_dir" apply -auto-approve "$plan_file" -no-color
  if declare -F persist_terraform_state_from_workspace >/dev/null 2>&1; then
    persist_terraform_state_from_workspace "$tf_dir"
  fi
  ui_done "Terraform destroy completed"
}
