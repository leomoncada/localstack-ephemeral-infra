variable "project_name" {
  type        = string
  description = "Prefix for all resource names."
  default     = "ephemeral-infra"
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention. Finite by policy; asserted by tests."
  default     = 7
}

variable "aws_endpoint_url" {
  type        = string
  description = "When set, redirects all AWS service calls to this endpoint (LocalStack). Empty means real AWS."
  default     = ""
}
