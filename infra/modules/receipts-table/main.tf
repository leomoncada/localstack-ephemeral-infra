resource "aws_dynamodb_table" "this" {
  #checkov:skip=CKV_AWS_119:KMS is out of scope for this repo (not in docker-compose's SERVICES or the provider's endpoints block); the table relies on DynamoDB's default AWS-owned-key encryption at rest instead of a customer-managed CMK.
  name         = "${var.project_name}-receipts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "receipt_id"

  attribute {
    name = "receipt_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}
