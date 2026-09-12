#!/usr/bin/env bash
# Portal, CM, Caddy, and monitoring URLs for Jenkins console + email (jenkins/artifacts/access-urls.txt).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/jenkins/artifacts}"
ANSIBLE_DIR="${REPO_ROOT}/ansible-playbooks"
ALL_YML="${ANSIBLE_DIR}/group_vars/all.yml"
OVERRIDE_YML="${ANSIBLE_DIR}/jenkins_override.yml"
INVENTORY="${INVENTORY:-$OUT_DIR/inventory.ini}"
[[ -f "$INVENTORY" ]] || INVENTORY="${ANSIBLE_DIR}/inventory.ini"
OUT_FILE="${OUT_DIR}/access-urls.txt"

strip_ansi() {
  sed -E \
    -e 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
    -e 's/\x1B\][^\x07]*(\x07|\x1B\\)//g'
}

sanitize_url_line() {
  local line="$1"
  line="$(printf '%s' "$line" | strip_ansi)"
  line="$(printf '%s' "$line" | tr -d '\r')"
  # Trim trailing non-URL junk (ANSI leftovers, box-drawing) often copied from Jenkins console.
  line="$(printf '%s' "$line" | sed -E 's/[^[:print:][:space:]]//g' | sed -E 's/[[:space:]]+$//')"
  printf '%s' "$line"
}

read_group_var() {
  local key="$1" default="${2:-}"
  local val="" f line
  for f in "$ALL_YML" "$OVERRIDE_YML"; do
    [[ -f "$f" ]] || continue
    line="$(grep -E "^${key}:" "$f" 2>/dev/null | head -1 || true)"
    if [[ -n "$line" ]]; then
      val="$(printf '%s' "$line" | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")"
    fi
  done
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
}

inventory_group_has_hosts() {
  local group="$1"
  [[ -f "$INVENTORY" ]] || return 1
  awk -v g="$group" '
    $0 == "[" g "]" { in_g=1; next }
    /^\[/ { in_g=0 }
    in_g && /^[^#[:space:]]/ { found=1; exit }
    END { exit !found }
  ' "$INVENTORY"
}

inventory_first_host_fields() {
  local group="$1"
  [[ -f "$INVENTORY" ]] || return 1
  awk -v g="$group" '
    $0 == "[" g "]" { in_g=1; next }
    /^\[/ { in_g=0 }
    in_g && /^[^#[:space:]]/ {
      print $0
      exit
    }
  ' "$INVENTORY"
}

parse_host_line() {
  local line="$1"
  HOST_NAME="${line%% *}"
  HOST_PUB=""
  HOST_PRIV=""
  HOST_SHORT=""
  for tok in $line; do
    case "$tok" in
      ansible_host=*) HOST_PUB="${tok#ansible_host=}" ;;
      private_ip=*) HOST_PRIV="${tok#private_ip=}" ;;
      cldr_hostname=*) HOST_SHORT="${tok#cldr_hostname=}" ;;
    esac
  done
  [[ -z "$HOST_PRIV" ]] && HOST_PRIV="$HOST_PUB"
  [[ -z "$HOST_SHORT" ]] && HOST_SHORT="$HOST_NAME"
}

caddy_hostname() {
  local svc="$1" ip_slug="$2" base="$3" mode="$4"
  case "$mode" in
    flat) printf '%s.%s' "$svc" "$base" ;;
    classic_nipio) printf '%s.%s.nip.io' "$svc" "$ip_slug" ;;
    *) printf '%s.%s.%s' "$svc" "$ip_slug" "$base" ;;
  esac
}

url_with_port() {
  local scheme="$1" host="$2" port="$3" path="${4:-/}"
  if [[ "$port" == "80" && "$scheme" == "http" ]]; then
    printf '%s://%s%s' "$scheme" "$host" "$path"
  elif [[ "$port" == "443" && "$scheme" == "https" ]]; then
    printf '%s://%s%s' "$scheme" "$host" "$path"
  else
    printf '%s://%s:%s%s' "$scheme" "$host" "$port" "$path"
  fi
}

extract_urls_from_ansible_logs() {
  local merged="" f latest=""
  for f in "$OUT_DIR"/ansible-*-phase*.log; do
    [[ -f "$f" ]] || continue
    if grep -q 'CDP_ACCESS_URLS_BEGIN' "$f" 2>/dev/null; then
      latest="$f"
    fi
  done
  [[ -n "$latest" ]] || return 1
  merged="$(awk '/CDP_ACCESS_URLS_BEGIN/,/CDP_ACCESS_URLS_END/' "$latest" | strip_ansi)"
  [[ -n "$merged" ]] || return 1
  printf '%s\n' "$merged"
  return 0
}

mkdir -p "$OUT_DIR"

{
  echo "CDP Deployment - Access URLs (portal, CM, Caddy, monitoring)"
  echo "=============================================================="
  echo "Build: ${JOB_NAME:-local} #${BUILD_NUMBER:-0}"
  echo "Time:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo ""

  if extract_urls_from_ansible_logs; then
    echo ""
    echo "(Above block copied from latest Ansible CDP_ACCESS_URLS report in phase logs.)"
    echo ""
  fi

  portal_enabled="$(read_group_var deployment_portal_enabled true)"
  if [[ "$portal_enabled" != "true" && "$portal_enabled" != "1" ]]; then
    echo "Deployment portal disabled (deployment_portal_enabled=false)."
    exit 0
  fi

  http_port="$(read_group_var deployment_portal_http_port 81)"
  pg_port="$(read_group_var deployment_portal_pgadmin_host_port 5050)"
  grafana_port="$(read_group_var monitoring_grafana_host_port 3000)"
  prom_port="$(read_group_var monitoring_prometheus_host_port 9090)"
  am_port="$(read_group_var monitoring_alertmanager_host_port 9093)"
  cadvisor_port="$(read_group_var monitoring_cadvisor_host_port 8089)"
  cm_http="$(read_group_var cm_http_port 7180)"
  cm_https="$(read_group_var cm_https_port 7183)"
  cluster_domain="$(read_group_var ipaserver_domain '')"
  [[ -z "$cluster_domain" ]] && cluster_domain="$(read_group_var cluster_domain '')"
  caddy_on="$(read_group_var caddy_vhost_enabled true)"
  caddy_mode="$(read_group_var caddy_vhost_dns_mode embedded_ip)"
  caddy_base="$(read_group_var caddy_vhost_public_base pvc.cloudera-labs.com)"
  ecs_app_domain="$(read_group_var ecs_app_domain '')"
  monitoring_on="$(read_group_var monitoring_stack_enabled true)"

  ops_group="cldr-mngr"
  if inventory_group_has_hosts ipaserver; then
    ops_group="ipaserver"
  fi

  ops_line="$(inventory_first_host_fields "$ops_group" || true)"
  cm_line="$(inventory_first_host_fields cldr-mngr || true)"

  if [[ -z "$ops_line" ]]; then
    echo "Ops host not found in inventory (expected [ipaserver] or [cldr-mngr])."
    exit 0
  fi

  parse_host_line "$ops_line"
  ops_pub="$HOST_PUB"
  ops_priv="$HOST_PRIV"
  ops_short="$HOST_SHORT"
  ops_fqdn="${ops_short}.${cluster_domain}"

  parse_host_line "${cm_line:-$ops_line}"
  cm_pub="$HOST_PUB"
  cm_priv="$HOST_PRIV"
  cm_short="$HOST_SHORT"
  cm_fqdn="${cm_short}.${cluster_domain}"

  private_profile="false"
  if [[ "$ops_pub" == "$ops_priv" ]]; then
    private_profile="true"
  fi

  echo "Computed from inventory + group_vars (use when portal playbooks did not run):"
  echo "Ops host group: $ops_group"
  echo ""

  echo "--- Direct URLs (no Caddy) ---"
  if [[ "$private_profile" == "true" ]]; then
    echo "Private / bare metal profile:"
    echo "  Portal:     $(url_with_port http "$ops_fqdn" "$http_port" /)"
    echo "  pgAdmin:    $(url_with_port http "$ops_fqdn" "$pg_port" /)"
    if [[ "$monitoring_on" == "true" || "$monitoring_on" == "1" ]]; then
      gf_path="/grafana/"
      prom_path="/prometheus/"
      am_path="/alertmanager/"
      if [[ "$caddy_on" == "true" || "$caddy_on" == "1" ]]; then
        gf_path="/"
        prom_path="/"
        am_path="/"
      fi
      echo "  Grafana:    $(url_with_port http "$ops_fqdn" "$grafana_port" "$gf_path")"
      echo "  Prometheus: $(url_with_port http "$ops_fqdn" "$prom_port" "$prom_path")"
      echo "  Alertmanager: $(url_with_port http "$ops_fqdn" "$am_port" "$am_path")"
      echo "  cAdvisor:   $(url_with_port http "$ops_fqdn" "$cadvisor_port" /)"
      echo "  (Caddy paths on :${http_port}: /grafana/, /prometheus/, /alertmanager/)"
    fi
  else
    echo "Public (Jenkins / internet):"
    echo "  Portal:     $(url_with_port http "$ops_pub" "$http_port" /)"
    echo "  pgAdmin:    $(url_with_port http "$ops_pub" "$pg_port" /)"
    if [[ "$monitoring_on" == "true" || "$monitoring_on" == "1" ]]; then
      gf_path="/grafana/"
      prom_path="/prometheus/"
      am_path="/alertmanager/"
      if [[ "$caddy_on" == "true" || "$caddy_on" == "1" ]]; then
        gf_path="/"
        prom_path="/"
        am_path="/"
      fi
      echo "  Grafana:    $(url_with_port http "$ops_pub" "$grafana_port" "$gf_path")"
      echo "  Prometheus: $(url_with_port http "$ops_pub" "$prom_port" "$prom_path")"
      echo "  Alertmanager: $(url_with_port http "$ops_pub" "$am_port" "$am_path")"
      echo "  cAdvisor:   $(url_with_port http "$ops_pub" "$cadvisor_port" /)"
      echo "  (Caddy paths on :${http_port}: /grafana/, /prometheus/, /alertmanager/)"
    fi
    echo "VPC private IP:"
    echo "  Portal:     $(url_with_port http "$ops_priv" "$http_port" /)"
    echo "  pgAdmin:    $(url_with_port http "$ops_priv" "$pg_port" /)"
    if [[ "$monitoring_on" == "true" || "$monitoring_on" == "1" ]]; then
      gf_path="/grafana/"
      prom_path="/prometheus/"
      am_path="/alertmanager/"
      if [[ "$caddy_on" == "true" || "$caddy_on" == "1" ]]; then
        gf_path="/"
        prom_path="/"
        am_path="/"
      fi
      echo "  Grafana:    $(url_with_port http "$ops_priv" "$grafana_port" "$gf_path")"
      echo "  Prometheus: $(url_with_port http "$ops_priv" "$prom_port" "$prom_path")"
      echo "  Alertmanager: $(url_with_port http "$ops_priv" "$am_port" "$am_path")"
      echo "  cAdvisor:   $(url_with_port http "$ops_priv" "$cadvisor_port" /)"
      echo "  (Caddy paths on :${http_port}: /grafana/, /prometheus/, /alertmanager/)"
    fi
  fi
  echo ""
  echo "Cloudera Manager (direct):"
  echo "  HTTP:  $(url_with_port http "$cm_fqdn" "$cm_http" /)"
  echo "  HTTPS: $(url_with_port https "$cm_fqdn" "$cm_https" /)"
  echo "  By public IP: http://${cm_pub}:${cm_http}/"
  echo "  By private IP: http://${cm_priv}:${cm_http}/"
  echo ""

  if [[ "$caddy_on" == "true" || "$caddy_on" == "1" ]]; then
    slug="${ops_pub//./-}"
    echo "--- Caddy lab hostnames (reverse proxy) ---"
    echo "  Mode: ${caddy_mode}  base: ${caddy_base}"
    portal_h="$(caddy_hostname portal "$slug" "$caddy_base" "$caddy_mode")"
    pg_h="$(caddy_hostname pgadmin "$slug" "$caddy_base" "$caddy_mode")"
    echo "  Portal (Caddy vhost): $(url_with_port http "$portal_h" "$http_port" /)"
    echo "  Direct by public IP:  $(url_with_port http "$ops_pub" "$http_port" /)"
    echo "  pgAdmin (Caddy):      $(url_with_port http "$pg_h" "$http_port" /)"
    echo "  pgAdmin (direct):     $(url_with_port http "$ops_pub" "$pg_port" /)"
    if [[ "$monitoring_on" == "true" || "$monitoring_on" == "1" ]]; then
      graf_h="$(caddy_hostname grafana "$slug" "$caddy_base" "$caddy_mode")"
      echo "  Grafana: $(url_with_port http "$graf_h" "$http_port" /)"
    fi
    if [[ "$private_profile" != "true" && "$ops_pub" != "$ops_priv" ]]; then
      slug_priv="${ops_priv//./-}"
      portal_vpc="$(caddy_hostname portal "$slug_priv" "$caddy_base" "$caddy_mode")"
      echo "  Portal (VPC slug): $(url_with_port http "$portal_vpc" "$http_port" /)"
    fi
  else
    echo "--- Caddy: disabled (use direct URLs above) ---"
  fi

  if [[ -n "$ecs_app_domain" ]]; then
    echo ""
    echo "--- ECS control plane ---"
    echo "  Console (typical): https://console.${ecs_app_domain}/"
    echo "  Apps wildcard:     https://*.${ecs_app_domain}/"
  fi

  echo ""
  echo "Service URL verify tiers (RUNBOOK.md): Tier A = localhost on ops host (portal 127.0.0.1:<deployment_portal_http_port> (default 81)); CM manager IP/FQDN :7180 on cldr-mngr;"
  echo "Tier B = external printed URLs from Jenkins when ansible_control_reachability is public (warn if SG blocks ports)."
  echo ""
  echo "Vars: deployment_external_url_verify (global), deployment_cm_external_url_verify (per-service)."
  echo "Grep Ansible logs: CDP_ACCESS_URLS_BEGIN  or  Tier B (external)"
} > "$OUT_FILE"

printf '[access-urls] Wrote %s\n' "$OUT_FILE"
