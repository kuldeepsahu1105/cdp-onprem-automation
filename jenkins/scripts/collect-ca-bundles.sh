#!/usr/bin/env bash
# Collect public CA certificates and document their authoritative server paths.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/jenkins/artifacts}"
INVENTORY="${INVENTORY:-$REPO_ROOT/ansible-playbooks/inventory.ini}"
REPORT="$OUT_DIR/ca-bundles.txt"

mkdir -p "$OUT_DIR"

first_host_in_group() {
  local group="$1"
  [[ -f "$INVENTORY" ]] || return 1
  awk -v group="$group" '
    $0 == "[" group "]" { active=1; next }
    /^\[/ { active=0 }
    active && /^[^#;[:space:]]/ {
      print $1
      exit
    }
  ' "$INVENTORY"
}

first_host() {
  local group host
  for group in "$@"; do
    host="$(first_host_in_group "$group" || true)"
    if [[ -n "$host" ]]; then
      printf '%s' "$host"
      return 0
    fi
  done
  return 1
}

fetch_ca() {
  local host="$1" remote_path="$2" local_name="$3"
  [[ -n "$host" && -f "$INVENTORY" ]] || return 1
  command -v ansible >/dev/null 2>&1 || return 1
  ansible "$host" -i "$INVENTORY" -b \
    -m ansible.builtin.fetch \
    -a "src=$remote_path dest=$OUT_DIR/$local_name flat=yes" \
    >/dev/null 2>&1 || return 1
  openssl x509 -in "$OUT_DIR/$local_name" -noout >/dev/null 2>&1 || {
    rm -f "$OUT_DIR/$local_name"
    return 1
  }
}

ipa_host="$(first_host ipaserver ipa_server || true)"
cm_host="$(first_host cldr-mngr cloudera_manager cm_server || true)"

ipa_status="not collected"
cm_status="not collected"

if fetch_ca "$ipa_host" /etc/ipa/ca.crt freeipa-ca.crt; then
  ipa_status="attached as freeipa-ca.crt"
fi
if fetch_ca "$cm_host" /var/lib/cloudera-scm-agent/agent-cert/cm-auto-in_cluster_ca_cert.pem cm-autotls-ca.crt; then
  cm_status="attached as cm-autotls-ca.crt"
fi

rm -f "$OUT_DIR/cm-ipa-ca-bundle.pem"
if [[ -f "$OUT_DIR/cm-autotls-ca.crt" || -f "$OUT_DIR/freeipa-ca.crt" ]]; then
  for cert in "$OUT_DIR/cm-autotls-ca.crt" "$OUT_DIR/freeipa-ca.crt"; do
    [[ -f "$cert" ]] && cat "$cert" >>"$OUT_DIR/cm-ipa-ca-bundle.pem"
  done
fi

cat >"$REPORT" <<EOF
CDP Deployment - CM and FreeIPA CA certificates
================================================

FreeIPA CA
  Authoritative server: ${ipa_host:-not present in inventory}
  Remote path: /etc/ipa/ca.crt
  Result: $ipa_status
  Use: FreeIPA HTTPS/LDAPS and clients that trust FreeIPA-issued certificates.

Cloudera Manager Auto-TLS CA
  Authoritative server: ${cm_host:-not present in inventory}
  Remote path: /var/lib/cloudera-scm-agent/agent-cert/cm-auto-in_cluster_ca_cert.pem
  Result: $cm_status
  Use: CM UI/API and Auto-TLS-enabled cluster service certificates.

Combined bundle
  Artifact: cm-ipa-ca-bundle.pem
  Contents: available CM Auto-TLS CA followed by the FreeIPA CA.
  Use: clients that must trust both CM/cluster Auto-TLS and FreeIPA TLS.

Only public certificates are collected. CA private keys are never copied or emailed.
EOF

printf '[collect] wrote: %s\n' "$REPORT"
