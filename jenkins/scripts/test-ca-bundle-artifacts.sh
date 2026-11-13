#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

bash -n \
  "$ROOT/jenkins/scripts/collect-ca-bundles.sh" \
  "$ROOT/jenkins/scripts/collect-artifacts.sh"

OUT_DIR="$TMP_DIR/artifacts" \
INVENTORY="$TMP_DIR/missing-inventory.ini" \
  "$ROOT/jenkins/scripts/collect-ca-bundles.sh"

grep -q '/etc/ipa/ca.crt' "$TMP_DIR/artifacts/ca-bundles.txt"
grep -q '/var/lib/cloudera-scm-agent/agent-cert/cm-auto-in_cluster_ca_cert.pem' \
  "$TMP_DIR/artifacts/ca-bundles.txt"
grep -q 'cm-ipa-ca-bundle.pem' "$TMP_DIR/artifacts/ca-bundles.txt"
grep -q 'collect-ca-bundles.sh' "$ROOT/jenkins/scripts/collect-artifacts.sh"
grep -q "'jenkins/artifacts/cm-ipa-ca-bundle.pem'" "$ROOT/Jenkinsfile"
grep -q "'jenkins/artifacts/\\*.crt'" "$ROOT/Jenkinsfile"
grep -q "caFiles.split('\\\\n').each { caPath ->" "$ROOT/Jenkinsfile"
grep -q 'def caRel = caPath.replace' "$ROOT/Jenkinsfile"

echo "CA bundle artifact checks passed"
