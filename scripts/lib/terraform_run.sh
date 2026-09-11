#!/usr/bin/env bash
# Terraform init / plan / apply with quiet CI-friendly console output.

# shellcheck source=scripts/lib/output_mode.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output_mode.sh"
# shellcheck source=scripts/lib/terraform_plan_output.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/terraform_plan_output.sh"

terraform_init_quiet() {
  local tf_dir="${1:-.}"
  local init_log rc

  if ! output_is_quiet; then
    terraform -chdir="$tf_dir" init -input=false -no-color
    return $?
  fi

  init_log="$(output_terraform_init_log)"
  mkdir -p "$(dirname "$init_log")"
  if terraform -chdir="$tf_dir" init -input=false -no-color >"$init_log" 2>&1; then
    if declare -F ui_ok >/dev/null 2>&1; then
      ui_ok "Terraform init OK"
    else
      printf '[terraform] init OK\n'
    fi
    if output_is_verbose; then
      cat "$init_log"
    elif ! output_is_quiet; then
      grep -E '^(Terraform has been successfully initialized|Initializing)' "$init_log" | tail -3 || true
    fi
    return 0
  fi
  rc=$?
  if declare -F ui_err >/dev/null 2>&1; then
    ui_err "Terraform init failed (see ${init_log})"
  else
    printf '[terraform] init FAILED — see %s\n' "$init_log" >&2
  fi
  cat "$init_log"
  return "$rc"
}

terraform_run_apply() {
  local tf_dir="${1:-.}"
  local plan_file="${2:-tfplan.out}"
  local apply_log rc

  apply_log="$(output_terraform_apply_log)"
  mkdir -p "$(dirname "$apply_log")"

  if output_is_verbose; then
    terraform -chdir="$tf_dir" apply -auto-approve "$plan_file" -no-color | tee "$apply_log"
    return "${PIPESTATUS[0]}"
  fi

  set +o pipefail
  terraform -chdir="$tf_dir" apply -auto-approve "$plan_file" -no-color 2>&1 \
    | tee "$apply_log" | output_filter_terraform_apply_stream
  rc="${PIPESTATUS[0]}"
  set -o pipefail

  if [[ "$rc" -ne 0 ]]; then
    if declare -F ui_err >/dev/null 2>&1; then
      ui_err "Terraform apply failed (exit ${rc}) — see ${apply_log}"
    else
      printf '[terraform] apply FAILED (exit %s) — see %s\n' "$rc" "$apply_log" >&2
    fi
    return "$rc"
  fi

  if grep -q '^Apply complete!' "$apply_log"; then
    line="$(grep '^Apply complete!' "$apply_log" | tail -1)"
    if declare -F ui_ok >/dev/null 2>&1; then
      ui_ok "$line"
    else
      printf '[terraform] %s\n' "$line"
    fi
  fi

  if output_is_quiet; then
    if declare -F ui_info >/dev/null 2>&1; then
      ui_info "Full apply log (incl. outputs): ${apply_log}"
    else
      printf '[terraform] full apply log: %s\n' "$apply_log"
    fi
  fi
  return 0
}
