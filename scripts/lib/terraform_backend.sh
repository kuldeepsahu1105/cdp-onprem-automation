#!/usr/bin/env bash
# S3 remote backend for Terraform (persists state across Jenkins workspace wipes).

terraform_backend_enabled() {
  case "${TF_STATE_BACKEND:-s3}" in
    s3|S3|remote) return 0 ;;
    local|none|off) return 1 ;;
    *) return 0 ;;
  esac
}

terraform_init_backend() {
  local tf_dir="${1:-.}"
  local bucket key region dynamodb_table
  local -a init_args=(-input=false)
  local -a backend_args=()

  if ! terraform_backend_enabled; then
    printf '[tf-backend] Using local state (TF_STATE_BACKEND=%s)\n' "${TF_STATE_BACKEND:-local}"
    terraform -chdir="$tf_dir" init -input=false
    return 0
  fi

  bucket="${TF_STATE_BUCKET:-pvc-cluster-terraform-backend}"
  key="${TF_STATE_KEY:-pvc-cluster/terraform.tfstate}"
  region="${TF_STATE_REGION:-${AWS_REGION:-ap-southeast-1}}"
  dynamodb_table="${TF_STATE_DYNAMODB_TABLE:-pvc-terraform-lock-table}"

  printf '[tf-backend] Initializing S3 backend bucket=%s key=%s region=%s\n' "$bucket" "$key" "$region"

  # Migrate local state file to S3 on first remote init (laptop → Jenkins handoff).
  if [[ -f "${tf_dir}/terraform.tfstate" ]]; then
    init_args+=(-migrate-state)
  fi

  backend_args=(
    -backend-config="bucket=${bucket}"
    -backend-config="key=${key}"
    -backend-config="region=${region}"
  )

  # DynamoDB state locking (compatible with Terraform < 1.10; do not use use_lockfile).
  if [[ -n "$dynamodb_table" && "$dynamodb_table" != "none" && "$dynamodb_table" != "false" ]]; then
    backend_args+=(-backend-config="dynamodb_table=${dynamodb_table}")
    printf '[tf-backend] State lock table: %s\n' "$dynamodb_table"
  fi

  terraform -chdir="$tf_dir" init "${init_args[@]}" "${backend_args[@]}"
}
