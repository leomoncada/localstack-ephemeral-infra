output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}

# Exposed so the suite can assert the dead-letter queue stays empty, i.e. that
# the handler rejects bad input rather than failing the invocation. Without
# this the DLQ would be provisioned and IAM-granted but never exercised.
output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}
