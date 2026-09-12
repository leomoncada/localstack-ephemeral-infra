output "receipts_table_name" {
  value = module.receipts_table.name
}

output "receipts_table_arn" {
  value = module.receipts_table.arn
}

output "ingest_bucket_name" {
  value = module.ingest_bucket.name
}

output "ingest_bucket_arn" {
  value = module.ingest_bucket.arn
}

output "processor_function_name" {
  value = module.processor_lambda.function_name
}

output "processor_role_name" {
  value = module.processor_lambda.role_name
}
