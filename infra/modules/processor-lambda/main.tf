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
  name              = "/aws/lambda/${var.project_name}-processor"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# Failed asynchronous invocations land here rather than being dropped after
# Lambda's retries. A real dead-letter target is preferable to arguing the case
# for not having one.
resource "aws_sqs_queue" "dlq" {
  name = "${var.project_name}-processor-dlq"

  # SSE-KMS under the stack key. Mutually exclusive with sqs_managed_sse_enabled,
  # so that attribute is gone rather than merely overridden.
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

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

  # The ingest bucket, the receipts table and the dead-letter queue are all
  # encrypted under the stack's customer-managed key, so the role needs to use
  # that key: Decrypt to read an SSE-KMS object out of the bucket,
  # GenerateDataKey to write to the SSE-KMS dead-letter queue. Scoped to the
  # one key, not to kms:*.
  statement {
    sid       = "UseStackEncryptionKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.project_name}-processor"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_173:The environment block below holds one variable, a DynamoDB table name, which is already published in this stack's Terraform outputs and in the function's own IAM policy. It is not a secret, and Lambda encrypts it at rest under the AWS-managed key regardless; a customer-managed CMK here would add key lifecycle management around a value that is public by construction. `kms_key_arn` was implemented and applied first: LocalStack accepts the argument, does not persist it (GetFunctionConfiguration returns KMSKeyArn: null) and so leaves a permanent one-line plan diff. Suppressing it beats carrying a LocalStack-shaped `ignore_changes` into code that is supposed to be target-agnostic. See PARITY-NOTES.md, "Customer-managed KMS keys".
  #checkov:skip=CKV_AWS_117:This function's only dependencies are S3, DynamoDB, SQS, KMS and CloudWatch Logs -- public AWS service endpoints, reached with a role scoped to five concrete ARNs. There is no private resource for it to reach, so a VPC would add subnets, route tables, security groups and either a NAT gateway or four interface endpoints -- a networking subsystem larger than the stack it protects -- and isolate the function from nothing it can currently talk to.
  #checkov:skip=CKV_AWS_272:Code signing closes the gap between building a deployment artifact and deploying it. Here there is no gap: the zip is produced by archive_file from `src/handler/` in this repository during the same `terraform apply` that uploads it, and source_code_hash ties the deployed code to that content. A signing profile would also need signing material issued against a real AWS account, which is state this stack deliberately does not hold.
  #checkov:skip=CKV_AWS_50:Active tracing requires xray:PutTraceSegments and xray:PutTelemetryRecords, neither of which supports resource-level permissions -- AWS grants them only as Resource "*". test_processor_role_grants_no_wildcard_resources asserts, against the live role, that no inline statement does that. Enabling tracing_config without the grant would ship a function that advertises tracing and silently emits nothing, which is worse than not claiming it. The enforceable least-privilege contract is kept instead.
  function_name    = "${var.project_name}-processor"
  role             = aws_iam_role.this.arn
  handler          = "app.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  timeout          = 30

  # 5 concurrent executions: the ingest workload is a trickle of independent
  # single-object events, so this is well above steady-state demand while
  # still bounding the writer count against the receipts table and capping the
  # blast radius of a sudden bulk upload. Any finite limit satisfies
  # CKV_AWS_115; this one is sized to the workload rather than picked to
  # silence it.
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
