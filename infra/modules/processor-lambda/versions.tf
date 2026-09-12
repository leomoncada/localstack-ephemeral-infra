# Declared per module, not inherited: a child module without its own
# required_providers picks up whatever the caller happens to have configured,
# and the version constraint that actually governs it becomes invisible from
# here. tflint's terraform_required_providers rule enforces this.
terraform {
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
}
