# Real-AWS target. Fill bucket with a state bucket you own before using.
bucket       = "CHANGE-ME-your-tfstate-bucket"
key          = "ephemeral-infra/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
