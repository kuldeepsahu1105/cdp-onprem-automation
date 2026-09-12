terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state — persisted on Jenkins agent under holautosa HOL_AUTO_EXEC_DIR (see holautosa_exec_dir.sh).
}
