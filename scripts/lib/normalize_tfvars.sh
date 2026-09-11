#!/usr/bin/env bash
# Normalize tfvars before terraform -var CLI (compact HCL lists, bool coercion).

normalize_tf_bool() {
  case "${1,,}" in
    true|1|yes|on) printf '%s' 'true' ;;
    *) printf '%s' 'false' ;;
  esac
}

# Terraform -var list values are sensitive to whitespace; use compact JSON/HCL lists.
normalize_tf_hcl_list() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 0
  printf '%s' "$raw" | tr -d '[:space:]'
}

normalize_tfvars_for_cli() {
  ALLOW_ALL="$(normalize_tf_bool "${ALLOW_ALL:-false}")"
  ALLOWED_CIDRS="$(normalize_tf_hcl_list "${ALLOWED_CIDRS:-}")"
  ALLOWED_PORTS="$(normalize_tf_hcl_list "${ALLOWED_PORTS:-}")"
  VPC_AZS="$(normalize_tf_hcl_list "${VPC_AZS:-}")"
  VPC_PUBLIC_SUBNETS_CIDR="$(normalize_tf_hcl_list "${VPC_PUBLIC_SUBNETS_CIDR:-}")"
  VPC_PRIVATE_SUBNETS_CIDR="$(normalize_tf_hcl_list "${VPC_PRIVATE_SUBNETS_CIDR:-}")"

  export ALLOW_ALL ALLOWED_CIDRS ALLOWED_PORTS VPC_AZS VPC_PUBLIC_SUBNETS_CIDR VPC_PRIVATE_SUBNETS_CIDR
}
