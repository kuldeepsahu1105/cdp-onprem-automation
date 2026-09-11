#!/usr/bin/env bash
# Jenkins-only overrides applied after tfvars load (BUILD_NUMBER is set in CI).

apply_jenkins_pipeline_defaults() {
  [[ -n "${BUILD_NUMBER:-}" ]] || return 0

  local suffix="${KEYPAIR_NAME_SUFFIX:-pvc-new-keypair}"

  export CREATE_KEYPAIR=true
  export KEYPAIR_NAME="${ENVIRONMENT}-${suffix}"

  printf '[jenkins-tfvars] CREATE_KEYPAIR=true KEYPAIR_NAME=%s\n' "$KEYPAIR_NAME"
}
