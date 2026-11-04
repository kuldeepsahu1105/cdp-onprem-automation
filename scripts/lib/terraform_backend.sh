#!/usr/bin/env bash
# Terraform init — local state only (state persisted under holautosa HOL_AUTO_EXEC_DIR).

_terraform_init_signature() {
  local tf_dir="$1"

  find "$tf_dir" \
    -path "$tf_dir/.terraform" -prune -o \
    -type f \( -name '*.tf' -o -name '.terraform.lock.hcl' \) \
    -exec cksum {} \; \
    | LC_ALL=C sort \
    | cksum \
    | awk '{print $1 ":" $2}'
}

terraform_init_backend() {
  local tf_dir="${1:-.}"
  local marker="${tf_dir}/.terraform/.cdp-init-signature"
  local signature

  signature="$(_terraform_init_signature "$tf_dir")"
  printf '[tf-backend] Local state (holautosa persistent dir when configured)\n'

  if [[ "${TERRAFORM_INIT_FORCE:-false}" != "true" ]] \
    && [[ -f "$marker" ]] \
    && [[ -f "${tf_dir}/.terraform/terraform.tfstate" ]] \
    && [[ "$(cat "$marker")" == "$signature" ]]; then
    printf '[tf-backend] Terraform already initialized for current configuration; skipping init\n'
    return 0
  fi

  terraform -chdir="$tf_dir" init -input=false
  signature="$(_terraform_init_signature "$tf_dir")"
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' "$signature" >"$marker"
}
