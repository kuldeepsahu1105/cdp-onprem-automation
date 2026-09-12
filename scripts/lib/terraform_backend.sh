#!/usr/bin/env bash
# Terraform init — local state only (state persisted under holautosa HOL_AUTO_EXEC_DIR).

terraform_init_backend() {
  local tf_dir="${1:-.}"
  printf '[tf-backend] Local state (holautosa persistent dir when configured)\n'
  terraform -chdir="$tf_dir" init -input=false
}
