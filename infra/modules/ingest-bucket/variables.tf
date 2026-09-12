variable "project_name" {
  type        = string
  description = "Prefix for the bucket name."
}

variable "kms_key_arn" {
  type        = string
  description = "Customer-managed KMS key the bucket encrypts objects under."
}
