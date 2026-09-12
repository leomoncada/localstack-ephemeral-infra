data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/handler.zip"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.project_name}-processor"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_338:A one-year retention would outlive the stack it describes: this is an ephemeral stack whose entire backing store is discarded by `make down` (`docker compose down -v`). Retention is finite and parameterised via var.log_retention_days, which test_processor_log_group_has_finite_retention asserts against the live resource.
  #checkov:skip=CKV_AWS_158:KMS is out of scope for this repo (not in docker-compose's SERVICES or the provider's endpoints block); the group relies on CloudWatch Logs' default server-side encryption rather than a customer-managed CMK.
  name              = "/aws/lambda/${var.project_name}-processor"
  retention_in_days = var.log_retention_days
}

# Failed asynchronous invocations land here rather than being dropped after
# Lambda's retries. SQS is available to this stack (it is in docker-compose's
# SERVICES), so a real dead-letter target is preferable to arguing the case
# for not having one.
resource "aws_sqs_queue" "dlq" {
  #checkov:skip=CKV_AWS_27:KMS is out of scope for this repo (not in docker-compose's SERVICES or the provider's endpoints block); sqs_managed_sse_enabled below still encrypts at rest with SSE-SQS, just not under a customer-managed CMK.
  name                      = "${var.project_name}-processor-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "ReadUploadedReceipts"
    actions   = ["s3:GetObject"]
    resources = ["${var.ingest_bucket_arn}/*"]
  }

  statement {
    sid       = "WriteReceipts"
    actions   = ["dynamodb:PutItem"]
    resources = [var.receipts_table_arn]
  }

  # No logs:CreateLogGroup: Terraform owns the group, so the function does not
  # need permission to create one. This is why the wildcard test can pass.
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid       = "SendFailuresToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.project_name}-processor"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_117:VPC networking is out of scope for this repo: EC2/VPC is absent from docker-compose's SERVICES and from the provider's endpoints block, so there is no VPC, subnet or security group for this stack to attach to.
  #checkov:skip=CKV_AWS_173:KMS is out of scope for this repo (not in docker-compose's SERVICES or the provider's endpoints block); the single environment variable is a table name, not a secret, and is encrypted at rest under the AWS-managed Lambda key rather than a customer-managed CMK.
  #checkov:skip=CKV_AWS_272:Code signing requires AWS Signer, which is absent from docker-compose's SERVICES and from the provider's endpoints block; a signing profile also requires signing material issued against a real AWS account, which an ephemeral local stack has no way to hold.
  #checkov:skip=CKV_AWS_50:X-Ray tracing requires the xray service, which is absent from docker-compose's SERVICES and from the provider's endpoints block; enabling Active tracing would emit trace segments to an endpoint this stack does not serve.
  function_name                  = "${var.project_name}-processor"
  role                           = aws_iam_role.this.arn
  handler                        = "app.handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.this.output_path
  source_code_hash               = data.archive_file.this.output_base64sha256
  timeout                        = 30
  reserved_concurrent_executions = 5

  environment {
    variables = {
      RECEIPTS_TABLE = var.receipts_table_name
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [
    aws_iam_role_policy.this,
    aws_cloudwatch_log_group.this,
  ]
}
