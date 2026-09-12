provider "aws" {
  region = var.region

  # LocalStack is selected by setting var.aws_endpoint_url; an empty string
  # (the default) falls through to real AWS. Every service the stack will ever
  # touch is listed: an omitted service silently routes to real AWS.
  endpoints {
    s3       = var.aws_endpoint_url
    lambda   = var.aws_endpoint_url
    dynamodb = var.aws_endpoint_url
    iam      = var.aws_endpoint_url
    sts      = var.aws_endpoint_url
    logs     = var.aws_endpoint_url
    sqs      = var.aws_endpoint_url
    events   = var.aws_endpoint_url
  }

  s3_use_path_style           = var.aws_endpoint_url != ""
  skip_credentials_validation = var.aws_endpoint_url != ""
  skip_metadata_api_check     = var.aws_endpoint_url != ""
  skip_requesting_account_id  = var.aws_endpoint_url != ""

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
