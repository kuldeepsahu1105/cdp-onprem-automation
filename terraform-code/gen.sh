#!/bin/bash

set -e

ROOT_DIR="cloudera-pvc-terraform"
MODULES=(ec2-instance key-pair security-group elastic-ip vpc)
MAIN_FILES=(main.tf variables.tf outputs.tf provider.tf terraform.tfvars)

echo "Creating root directory: $ROOT_DIR"
mkdir -p "$ROOT_DIR/modules"

cd "$ROOT_DIR"

# Create root Terraform files
echo "Creating root files..."
for file in "${MAIN_FILES[@]}"; do
  touch "$file"
done

# Create modules
echo "Creating module directories and files..."
for module in "${MODULES[@]}"; do
  mkdir -p "modules/$module"
  touch "modules/$module/main.tf" "modules/$module/variables.tf" "modules/$module/outputs.tf"
done

echo "Writing code to files..."

# ========== PROVIDER ==========
cat > provider.tf <<EOF
provider "aws" {
  region = var.aws_region
}
EOF

echo "✅ All Terraform files and folders have been created."
