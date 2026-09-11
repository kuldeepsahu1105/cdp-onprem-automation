#!/usr/bin/env bash
# Terraform init — local state only (state persisted under holautosa HOL_AUTO_EXEC_DIR).

terraform_init_backend() {
  local tf_dir="${1:-.}"
  # shellcheck source=scripts/lib/terraform_run.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/terraform_run.sh"
  output_is_quiet || printf '[tf-backend] Local state (holautosa persistent dir when configured)\n'
  terraform_init_quiet "$tf_dir"
}
