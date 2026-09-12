variable "project_name" {
  type        = string
  description = "Prefix for resource names."
}

variable "source_dir" {
  type        = string
  description = "Directory containing the handler source to package."
}

variable "receipts_table_name" {
  type        = string
  description = "DynamoDB table the handler writes to."
}

variable "receipts_table_arn" {
  type        = string
  description = "ARN of the receipts table, for the scoped IAM policy."
}

variable "ingest_bucket_arn" {
  type        = string
  description = "ARN of the ingest bucket, for the scoped IAM policy."
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch retention in days."
}

variable "kms_key_arn" {
  type        = string
  description = "Customer-managed KMS key for the log group and the dead-letter queue, and which the execution role is granted use of."
}
