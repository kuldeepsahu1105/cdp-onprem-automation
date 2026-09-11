#!/usr/bin/env bash
# Terraform plan console output control (Jenkins-friendly).

# shellcheck source=scripts/lib/output_mode.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output_mode.sh"

terraform_plan_output_enabled() {
  output_show_tf_plan
}

terraform_plan_detail_log_path() {
  local base="${LOG_DIR:-${REPO_ROOT:-.}/jenkins/artifacts}"
  printf '%s/terraform-plan-%s-detail.log' "$base" "${BUILD_NUMBER:-local}"
}

terraform_print_plan_summary() {
  local plan_log="$1"
  local line created updated destroyed replaced

  if [[ ! -f "$plan_log" ]]; then
    return 0
  fi

  if line="$(grep -E '^No changes\.' "$plan_log" | tail -1)" && [[ -n "$line" ]]; then
    if output_is_quiet; then
      log_milestone "$line"
    elif declare -F ui_ok >/dev/null 2>&1; then
      ui_ok "$line"
    else
      printf '[terraform-plan] %s\n' "$line"
    fi
    return 0
  fi

  line="$(grep -E '^Plan: ' "$plan_log" | tail -1)"
  if [[ -n "$line" ]]; then
    if output_is_quiet; then
      log_milestone "$line"
    elif declare -F ui_ok >/dev/null 2>&1; then
      ui_ok "$line"
    else
      printf '[terraform-plan] %s\n' "$line"
    fi
  fi

  if output_is_quiet; then
    return 0
  fi

  created="$(grep -cE ' will be created$' "$plan_log" 2>/dev/null || true)"
  updated="$(grep -cE ' will be updated in-place$' "$plan_log" 2>/dev/null || true)"
  destroyed="$(grep -cE ' will be destroyed$' "$plan_log" 2>/dev/null || true)"
  replaced="$(grep -cE ' must be replaced$' "$plan_log" 2>/dev/null || true)"
  created="${created:-0}"
  updated="${updated:-0}"
  destroyed="${destroyed:-0}"
  replaced="${replaced:-0}"

  if [[ "$created$updated$destroyed$replaced" != "0000" ]]; then
    if declare -F ui_kv >/dev/null 2>&1; then
      ui_kv "Plan detail" "create=${created} update=${updated} destroy=${destroyed} replace=${replaced}" "📊"
    else
      printf '[terraform-plan] create=%s update=%s destroy=%s replace=%s\n' \
        "$created" "$updated" "$destroyed" "$replaced"
    fi
  fi
}

# Run terraform plan. Full stdout when SHOW_TF_PLAN_OUTPUT=true (or VERBOSE); else summary only.
terraform_run_plan() {
  local tf_dir="${1:-.}"
  local plan_file="${2:-tfplan.out}"
  local plan_log rc

  plan_log="$(terraform_plan_detail_log_path)"
  mkdir -p "$(dirname "$plan_log")"

  if terraform_plan_output_enabled; then
    terraform -chdir="$tf_dir" plan "${TF_VARS[@]}" -out="$plan_file" -no-color
    return $?
  fi

  if ! output_is_quiet; then
    if declare -F ui_info >/dev/null 2>&1; then
      ui_info "Plan running (summary only). Set SHOW_TF_PLAN_OUTPUT=true for full plan in console."
    else
      printf '[terraform-plan] Plan running (summary only). Set SHOW_TF_PLAN_OUTPUT=true for full plan.\n'
    fi
  fi

  local errexit_on=0
  [[ $- == *e* ]] && errexit_on=1
  set +e
  terraform -chdir="$tf_dir" plan "${TF_VARS[@]}" -out="$plan_file" -no-color >"$plan_log" 2>&1
  rc=$?
  [[ "$errexit_on" == 1 ]] && set -e

  if [[ "$rc" -ne 0 ]]; then
    if declare -F ui_err >/dev/null 2>&1; then
      ui_err "Terraform plan failed (exit ${rc})"
    else
      printf '[terraform-plan] ERROR: plan failed (exit %s)\n' "$rc" >&2
    fi
    cat "$plan_log"
    return "$rc"
  fi

  terraform_print_plan_summary "$plan_log"
  if ! output_is_quiet; then
    if declare -F ui_info >/dev/null 2>&1; then
      ui_info "Full plan log: ${plan_log}"
    else
      printf '[terraform-plan] Full plan log: %s\n' "$plan_log"
    fi
  fi
  return 0
}
