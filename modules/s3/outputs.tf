output "bucket_name" {
  description = "The name of the S3 bucket"
  value       = aws_s3_bucket.crdb_backups.bucket
}

output "bucket_arn" {
  description = "The ARN of the S3 bucket"
  value       = aws_s3_bucket.crdb_backups.arn
}

output "bucket_id" {
  description = "The ID of the S3 bucket"
  value       = aws_s3_bucket.crdb_backups.id
}

output "iam_role_arn" {
  description = "ARN of the IAM role for CRDB S3 access"
  value       = aws_iam_role.crdb_backup_role.arn
}

output "iam_policy_arn" {
  description = "ARN of the IAM policy for S3 access"
  value       = aws_iam_policy.crdb_s3_access.arn
}