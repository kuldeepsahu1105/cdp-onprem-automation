#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/inventory.ini" <<'EOF'
[ipaserver]
ipa-node ansible_host=13.212.4.55 private_ip=172.31.68.233

[cldr-mngr]
cm-node ansible_host=52.76.86.2 private_ip=172.31.77.25

[ecs-masters]
ecs-node ansible_host=54.169.224.96 private_ip=172.31.79.41
EOF

REPO_ROOT="$repo_root" \
OUT_DIR="$tmp_dir" \
INVENTORY="$tmp_dir/inventory.ini" \
ENVIRONMENT="test" \
JOB_NAME="test-build" \
BUILD_NUMBER="1" \
ANSIBLE_PHASES="" \
PIPELINE_STAGES="" \
  "$repo_root/jenkins/scripts/build-cm-access-info.sh" >/dev/null

output="$(cat "$tmp_dir/cm-access.txt")"

grep -Fq \
  "Example (CM host): ssh -i <pem-file> ec2-user@52.76.86.2" \
  <<<"$output"
grep -Fq "http://52.76.86.2:7180/" <<<"$output"

if grep -Fq "ec2-user@13.212.4.55" <<<"$output"; then
  echo "CM SSH example incorrectly used the ipaserver address" >&2
  exit 1
fi

echo "CM access inventory group selection checks passed"
