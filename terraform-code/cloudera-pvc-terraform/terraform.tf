terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — configured at init via scripts/lib/terraform_backend.sh (-backend-config).
  # Per-environment workspaces map to env:/<workspace>/... in the bucket.
  backend "s3" {}
}