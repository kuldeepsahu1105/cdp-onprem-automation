#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

actual_defaults="$(
  env \
    -u CLDR_MNGR_INSTANCE_TYPE \
    -u IPA_SERVER_INSTANCE_TYPE \
    -u PVCBASE_MASTER_INSTANCE_TYPE \
    -u PVCBASE_WORKER_INSTANCE_TYPE \
    -u PVCECS_MASTER_INSTANCE_TYPE \
    -u PVCECS_WORKER_INSTANCE_TYPE \
    -u CPU_ARCHITECTURE \
    -u APPLY_GRAVITON_DEFAULTS \
    -u ECS_DEPLOY_ON_ARM64 \
    bash -c '
      source "$1/scripts/lib/tfvars_defaults.sh"
      printf "%s\n" \
        "$CLDR_MNGR_INSTANCE_TYPE" \
        "$IPA_SERVER_INSTANCE_TYPE" \
        "$PVCBASE_MASTER_INSTANCE_TYPE" \
        "$PVCBASE_WORKER_INSTANCE_TYPE" \
        "$PVCECS_MASTER_INSTANCE_TYPE" \
        "$PVCECS_WORKER_INSTANCE_TYPE"
    ' _ "$repo_root"
)"

expected_defaults=$'m6a.4xlarge\nm6a.large\nm6a.4xlarge\nm6a.4xlarge\nm6a.8xlarge\nm6a.8xlarge'
if [[ "$actual_defaults" != "$expected_defaults" ]]; then
  printf 'Unexpected shell defaults:\n%s\n' "$actual_defaults" >&2
  exit 1
fi

mapped_worker="$(
  bash -c '
    source "$1/scripts/lib/arch_defaults.sh"
    map_instance_type_to_graviton m6a.8xlarge
  ' _ "$repo_root"
)"
[[ "$mapped_worker" == "m7g.8xlarge" ]]

python3 - "$repo_root" <<'PY'
from pathlib import Path
import re
import sys
import yaml

root = Path(sys.argv[1])
expected = {
    "cldr_mngr": "m6a.4xlarge",
    "ipa_server": "m6a.large",
    "pvcbase_master": "m6a.4xlarge",
    "pvcbase_worker": "m6a.4xlarge",
    "pvcecs_master": "m6a.8xlarge",
    "pvcecs_worker": "m6a.8xlarge",
}

tfvars = yaml.safe_load((root / ".tfvars.yaml").read_text())
expected_ami = "ami-0ace6c94b5ab2e659"
assert tfvars["aws_region"] == "ap-southeast-1"
assert tfvars["ami_id"] == expected_ami
for group, instance_type in expected.items():
    assert tfvars["instance_groups"][group]["instance_type"] == instance_type

readme_md = (root / "README.md").read_text()
readme_adoc = (root / "README.adoc").read_text()
for group, instance_type in expected.items():
    assert re.search(
        rf"^\| `{re.escape(group)}` \|.*\b{re.escape(instance_type)}\b",
        readme_md,
        re.MULTILINE,
    ), f"README.md: {group}"
    assert re.search(
        rf"^\| `{re.escape(group)}`\n\| \d+\n\| {re.escape(instance_type)}$",
        readme_adoc,
        re.MULTILINE,
    ), f"README.adoc: {group}"

assert tfvars["ami_id"] in readme_adoc

jenkinsfile = (root / "Jenkinsfile").read_text()
assert f"defaultValue: '{expected_ami}'" in jenkinsfile
assert expected_ami in (root / "scripts/lib/tfvars_defaults.sh").read_text()
assert expected_ami in (root / "scripts/lib/arch_defaults.sh").read_text()
parameter_names = {
    "cldr_mngr": "CLDR_MNGR_INSTANCE_TYPE",
    "ipa_server": "IPA_SERVER_INSTANCE_TYPE",
    "pvcbase_master": "PVCBASE_MASTER_INSTANCE_TYPE",
    "pvcbase_worker": "PVCBASE_WORKER_INSTANCE_TYPE",
    "pvcecs_master": "PVCECS_MASTER_INSTANCE_TYPE",
    "pvcecs_worker": "PVCECS_WORKER_INSTANCE_TYPE",
}
for group, parameter_name in parameter_names.items():
    instance_type = expected[group]
    parameter_pattern = re.compile(
        rf"string\(name: '{parameter_name}', defaultValue: '{re.escape(instance_type)}'"
    )
    assert parameter_pattern.search(jenkinsfile), parameter_name
    assert (
        f'JENKINS_{parameter_name} = "${{params.{parameter_name}?.trim() ?: \'\'}}"'
        in jenkinsfile
    )
    assert f"'{parameter_name}'" in jenkinsfile

for relative_path in (
    "terraform-code/cloudera-pvc-terraform/variables.tf",
    "terraform-code/cloudera-pvc-terraform/modules/ec2-instance/variables.tf",
):
    terraform_text = (root / relative_path).read_text()
    for group, instance_type in expected.items():
        block_pattern = re.compile(
            rf"{group}\s*=\s*\{{.*?instance_type\s*=\s*\"{re.escape(instance_type)}\"",
            re.DOTALL,
        )
        assert block_pattern.search(terraform_text), f"{relative_path}: {group}"

for relative_path in (
    "terraform-code/cloudera-pvc-terraform/variables.tf",
    "terraform-code/cloudera-pvc-terraform/terraform.tfvars",
    "terraform-code/cloudera-pvc-terraform/modules/ec2-instance/variables.tf",
    "terraform-code/cloudera-pvc-terraform/modules/ec2-instance/terraform.tfvars",
):
    terraform_text = (root / relative_path).read_text()
    assert expected_ami in terraform_text, relative_path
    old_ami = "ami-" + "06dc977f58c8d7857"
    assert old_ami not in terraform_text, relative_path

print("Instance type defaults test passed")
PY
