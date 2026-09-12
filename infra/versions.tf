terraform {
  # 1.11 is the floor, not 1.10: `use_lockfile` (this backend's only locking
  # mechanism -- see env/local.backend.hcl) landed in 1.10 and is GA in 1.11,
  # which is also where `dynamodb_table` is formally deprecated. A reader on
  # 1.9 fails at `terraform init`.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Partial configuration. Supplied per target via -backend-config.
  backend "s3" {}
}
