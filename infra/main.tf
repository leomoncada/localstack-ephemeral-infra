module "receipts_table" {
  source       = "./modules/receipts-table"
  project_name = var.project_name
  kms_key_arn  = aws_kms_key.stack.arn
}

module "ingest_bucket" {
  source       = "./modules/ingest-bucket"
  project_name = var.project_name
  kms_key_arn  = aws_kms_key.stack.arn
}

module "processor_lambda" {
  source = "./modules/processor-lambda"

  project_name        = var.project_name
  source_dir          = "${path.module}/../src/handler"
  receipts_table_name = module.receipts_table.name
  receipts_table_arn  = module.receipts_table.arn
  ingest_bucket_arn   = module.ingest_bucket.arn
  log_retention_days  = var.log_retention_days
  kms_key_arn         = aws_kms_key.stack.arn
}

resource "aws_lambda_permission" "allow_ingest_bucket" {
  statement_id  = "AllowExecutionFromIngestBucket"
  action        = "lambda:InvokeFunction"
  function_name = module.processor_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.ingest_bucket.arn
}

resource "aws_s3_bucket_notification" "ingest" {
  bucket = module.ingest_bucket.id

  lambda_function {
    lambda_function_arn = module.processor_lambda.function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_ingest_bucket]
}
