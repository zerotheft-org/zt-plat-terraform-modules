# ---------------------------------------------------------------
# Calls the reusable S3 module.
# To change bucket name, lifecycle days, or add a new env —
# you only touch the arguments here, never the module itself.
# ---------------------------------------------------------------
module "s3_crdb_backups" {
  source = "../../../modules/s3"

  bucket_name = var.crdb_backups_bucket_name
  environment = var.environment
  tags        = var.tags
}
