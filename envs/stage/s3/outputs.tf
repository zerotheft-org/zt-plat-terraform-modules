output "bucket_name" {
  description = "S3 bucket name for CRDB backups"
  value       = module.s3_crdb_backups.bucket_name
}

output "bucket_arn" {
  description = "ARN of the CRDB backup bucket"
  value       = module.s3_crdb_backups.bucket_arn
}

output "iam_role_arn" {
  description = "IAM role ARN that can read/write the backup bucket"
  value       = module.s3_crdb_backups.iam_role_arn
}
