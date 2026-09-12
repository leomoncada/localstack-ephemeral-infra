bucket       = "tfstate"
key          = "ephemeral-infra/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true

# LocalStack-only. The backend does not inherit the provider's configuration,
# so its endpoint and credential handling must be repeated here.
access_key                  = "test"
secret_key                  = "test"
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
use_path_style              = true

endpoints = {
  s3 = "http://localhost:4566"
}
