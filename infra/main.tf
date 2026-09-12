module "receipts_table" {
  source       = "./modules/receipts-table"
  project_name = var.project_name
}

module "ingest_bucket" {
  source       = "./modules/ingest-bucket"
  project_name = var.project_name
}
