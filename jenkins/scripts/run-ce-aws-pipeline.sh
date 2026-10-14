#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM_DIR="${CE_AWS_DIR:-${REPO_ROOT}/.ce-aws}"
ARTIFACT_DIR="${REPO_ROOT}/jenkins/artifacts"
UPSTREAM_REPO="https://github.com/cloudera-labs/cloudera-ce-aws.git"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_inputs() {
  local selected=",${CE_AWS_STAGES:-},"
  local stage
  local allowed_stages="INFRASTRUCTURE SERVICES CMS OZONE KAFKA FLINK NIFI CSA PORTAL_ADDON MONITORING_ADDON TEARDOWN"
  local -a selected_stages

  [[ -n "${CE_AWS_STAGES:-}" ]] || die "Select at least one CE_AWS_STAGES entry"
  IFS=',' read -r -a selected_stages <<<"$CE_AWS_STAGES"
  for stage in "${selected_stages[@]}"; do
    stage="${stage//[[:space:]]/}"
    [[ " $allowed_stages " == *" $stage "* ]] || die "Unknown CE_AWS_STAGES entry: $stage"
  done
  if [[ "$selected" == *",TEARDOWN,"* && ${#selected_stages[@]} -ne 1 ]]; then
    die "TEARDOWN must be selected alone"
  fi

  [[ "${CE_NAME_PREFIX:-}" =~ ^[a-z][a-z0-9-]{2,5}[a-z0-9]$ ]] \
    || die "NAME_PREFIX must be 4-7 lowercase letters/digits/hyphens, start with a letter, and not end with a hyphen"
  [[ "${CE_AWS_REGION:-}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] \
    || die "AWS_REGION is invalid: ${CE_AWS_REGION:-<empty>}"
  [[ "${CE_OWNER_EMAIL:-}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die "OWNER_EMAIL must be a valid email address"
  [[ ${#CE_COMMON_PASSWORD} -ge 8 && "${CE_COMMON_PASSWORD}" =~ [0-9] ]] \
    || die "COMMON_PASSWORD must be at least 8 characters and contain a number"
  [[ "${CE_AWS_REF:-}" =~ ^[A-Za-z0-9._/-]+$ && "${CE_AWS_REF}" != *..* ]] \
    || die "CE_AWS_REF contains invalid characters"

  python3 - "${CE_JENKINS_IP:-}" <<'PY'
import ipaddress
import sys

value = sys.argv[1].strip()
if "/" in value:
    raise SystemExit("ERROR: JENKINS_IP must be one IPv4 address, not CIDR notation")
try:
    parsed = ipaddress.ip_address(value)
except ValueError as exc:
    raise SystemExit(f"ERROR: JENKINS_IP is invalid: {exc}") from exc
if parsed.version != 4:
    raise SystemExit("ERROR: JENKINS_IP must be IPv4")
PY
}

checkout_upstream() {
  if [[ ! -d "${UPSTREAM_DIR}/.git" ]]; then
    git clone "$UPSTREAM_REPO" "$UPSTREAM_DIR"
  fi
  git -C "$UPSTREAM_DIR" fetch --prune origin
  git -C "$UPSTREAM_DIR" fetch origin "$CE_AWS_REF"
  git -C "$UPSTREAM_DIR" checkout --detach FETCH_HEAD
  printf 'Using cloudera-ce-aws %s\n' "$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
}

write_generated_config() {
  install -d -m 0700 "$ARTIFACT_DIR"
  cp \
    "$REPO_ROOT/jenkins/ce-aws/portal-ingress.tf" \
    "$UPSTREAM_DIR/tf_cluster_aws/cdp_onprem_addons.tf"

  python3 - "$UPSTREAM_DIR/config.yml" <<'PY'
import json
import os
import pathlib

destination = pathlib.Path(os.sys.argv[1])
config = {
    "name_prefix": os.environ["CE_NAME_PREFIX"],
    "infra_region": os.environ["CE_AWS_REGION"],
    "common_password": os.environ["CE_COMMON_PASSWORD"],
    "owner_email": os.environ["CE_OWNER_EMAIL"],
    "ingress_cidr": [f'{os.environ["CE_JENKINS_IP"].strip()}/32'],
}
destination.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
destination.chmod(0o600)
PY

  if [[ -s "${CE_AWS_CONFIG_OVERRIDES_FILE:-}" ]]; then
    cp "$CE_AWS_CONFIG_OVERRIDES_FILE" "$UPSTREAM_DIR/config-overrides.yml"
  else
    printf '%s\n' '---' >"$UPSTREAM_DIR/config-overrides.yml"
  fi
  chmod 0600 "$UPSTREAM_DIR/config-overrides.yml"

  python3 - "$UPSTREAM_DIR/addon-config.yml" <<'PY'
import json
import os
import pathlib

destination = pathlib.Path(os.sys.argv[1])
password = os.environ["CE_COMMON_PASSWORD"]
config = {
    "ce_aws_addon_portal_enabled": False,
    "ce_aws_addon_monitoring_enabled": False,
    "deployment_portal_host_group": "reverse_proxy",
    "deployment_portal_postgres_host_group": "postgresql",
    "deployment_portal_http_port": 81,
    "deployment_portal_enabled": True,
    "deployment_portal_install_required": True,
    "deployment_portal_verify_tier_b_enabled": False,
    "caddy_vhost_enabled": True,
    "cluster_domain": "cldr.internal",
    "identity_provider": "freeipa",
    "ipaadmin_password": password,
    "common_password": password,
    "postgres_user": "db_admin",
    "postgres_password": password,
    "pgadmin_default_email": os.environ["CE_OWNER_EMAIL"],
    "pgadmin_default_password": password,
    "cm_admin_user": "admin",
    "cm_admin_pass": password,
    "base_cluster_ranger_admin_password": password,
    "monitoring_grafana_admin_password": password,
    "deployment_portal_basic_auth_password": password,
    "monitoring_node_exporter_host_groups": [
        "reverse_proxy",
        "freeipa",
        "cldr-mngr",
        "base-masters",
        "base-workers",
        "ecs-masters",
        "ecs-workers",
    ],
    "monitoring_process_exporter_host_groups": [
        "reverse_proxy",
        "freeipa",
        "cldr-mngr",
        "base-masters",
        "base-workers",
        "ecs-masters",
        "ecs-workers",
    ],
}
destination.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
destination.chmod(0o600)
PY

  if [[ -s "${CE_ADDON_OVERRIDES_FILE:-}" ]]; then
    cp "$CE_ADDON_OVERRIDES_FILE" "$UPSTREAM_DIR/addon-overrides.yml"
  else
    printf '%s\n' '---' >"$UPSTREAM_DIR/addon-overrides.yml"
  fi
  chmod 0600 "$UPSTREAM_DIR/addon-overrides.yml"
}

prepare_addon_tree() {
  local addon_root="$UPSTREAM_DIR/.local/cdp-onprem-automation"
  mkdir -p "$addon_root"
  rm -rf "$addon_root/ansible-playbooks"
  cp -R "$REPO_ROOT/ansible-playbooks" "$addon_root/ansible-playbooks"
}

navigator() {
  (
    cd "$UPSTREAM_DIR"
    ansible-navigator "$@" --mode stdout
  )
}

run_upstream_playbook() {
  local playbook="$1"
  local path="playbooks/${playbook}.yml"
  [[ -f "$UPSTREAM_DIR/$path" ]] || die "Unknown upstream playbook: $playbook"
  jenkins_log_pipe "$ARTIFACT_DIR/ce-aws-${playbook}.log" \
    navigator run "$path" -e @config-overrides.yml -e @config.yml
}

run_addon() {
  local addon="$1"
  local portal=false
  local monitoring=false
  case "$addon" in
    portal) portal=true ;;
    monitoring) monitoring=true ;;
    *) die "Unknown add-on: $addon" ;;
  esac

  prepare_addon_tree
  jenkins_log_pipe "$ARTIFACT_DIR/ce-aws-${addon}-addon.log" \
    navigator run .local/cdp-onprem-automation/ansible-playbooks/ce_aws_addons.yml \
      -i inventory.yml \
      -e @config.yml \
      -e @addon-config.yml \
      -e @addon-overrides.yml \
      -e "ce_aws_addon_portal_enabled=${portal}" \
      -e "ce_aws_addon_monitoring_enabled=${monitoring}"
}

cleanup_secrets() {
  rm -f \
    "$UPSTREAM_DIR/config.yml" \
    "$UPSTREAM_DIR/config-overrides.yml" \
    "$UPSTREAM_DIR/addon-config.yml" \
    "$UPSTREAM_DIR/addon-overrides.yml" \
    "$ARTIFACT_DIR/ce-aws-config-overrides.yml" \
    "$ARTIFACT_DIR/ce-aws-addon-overrides.yml"
}

main() {
  local action="${1:-}"

  if [[ "$action" == "cleanup-secrets" ]]; then
    cleanup_secrets
    return
  fi

  require_command git
  require_command python3

  # shellcheck source=scripts/lib/jenkins_log_pipe.sh
  source "$REPO_ROOT/scripts/lib/jenkins_log_pipe.sh"

  case "$action" in
    prepare)
      require_command ansible-navigator
      validate_inputs
      checkout_upstream
      write_generated_config
      ;;
    run)
      require_command ansible-navigator
      [[ -f "$UPSTREAM_DIR/config.yml" ]] || die "Generated upstream config is missing; run prepare first"
      run_upstream_playbook "${2:-}"
      ;;
    addon)
      require_command ansible-navigator
      [[ -f "$UPSTREAM_DIR/config.yml" ]] || die "Generated upstream config is missing; run prepare first"
      run_addon "${2:-}"
      ;;
    *)
      die "Usage: $0 {prepare|run <playbook>|addon <portal|monitoring>|cleanup-secrets}"
      ;;
  esac
}

main "$@"
