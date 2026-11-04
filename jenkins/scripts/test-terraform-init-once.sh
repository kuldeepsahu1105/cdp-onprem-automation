#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$workdir/bin" "$workdir/tf"
cat >"$workdir/tf/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.5"
}
EOF

cat >"$workdir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

tf_dir="."
for arg in "$@"; do
  case "$arg" in
    -chdir=*) tf_dir="${arg#-chdir=}" ;;
  esac
done

if [[ " $* " == *" init "* ]]; then
  count_file="${TF_INIT_COUNT_FILE:?}"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  printf '%s\n' "$((count + 1))" >"$count_file"
  mkdir -p "$tf_dir/.terraform"
  printf '{}\n' >"$tf_dir/.terraform/terraform.tfstate"
  printf '# generated during init\n' >"$tf_dir/.terraform.lock.hcl"
fi
EOF
chmod +x "$workdir/bin/terraform"

export PATH="$workdir/bin:$PATH"
export TF_INIT_COUNT_FILE="$workdir/init-count"

# shellcheck source=scripts/lib/terraform_backend.sh
source "$repo_root/scripts/lib/terraform_backend.sh"

terraform_init_backend "$workdir/tf"
terraform_init_backend "$workdir/tf"
[[ "$(cat "$TF_INIT_COUNT_FILE")" == "1" ]]

printf '\n# configuration changed\n' >>"$workdir/tf/main.tf"
terraform_init_backend "$workdir/tf"
[[ "$(cat "$TF_INIT_COUNT_FILE")" == "2" ]]

TERRAFORM_INIT_FORCE=true terraform_init_backend "$workdir/tf"
[[ "$(cat "$TF_INIT_COUNT_FILE")" == "3" ]]

grep -q "terraform_init_backend" "$repo_root/jenkins/scripts/run-ansible.sh"
! grep -q "holautosa_purge_terraform_module_cache" \
  "$repo_root/jenkins/scripts/run-terraform.sh"
! grep -q "holautosa_purge_terraform_module_cache" \
  "$repo_root/jenkins/scripts/run-terraform-destroy.sh"

python3 - "$repo_root/scripts/lib/holautosa_exec_dir.sh" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
restore = re.search(
    r"restore_terraform_state_to_workspace\(\) \{(?P<body>.*?)\n\}",
    text,
    re.DOTALL,
)
assert restore
assert "holautosa_purge_terraform_module_cache" not in restore.group("body")
PY

echo "Terraform init once-per-configuration checks passed"
