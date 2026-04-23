module "drift" {
  source = "../../../modules/drift"

  environment      = var.environment
  s3_bucket_name   = "zero-theft-crdb-backups-stage"
  crdb_secret_name = "stage/app/db-credentials"
  db_name          = "app_core_dev"
  tags             = var.tags
}
