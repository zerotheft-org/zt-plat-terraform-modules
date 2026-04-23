variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "stage"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "crdb_secret_name" {
  description = "Secrets Manager secret name containing CRDB connection details"
  type        = string
  default     = "stage/app/db-credentials"
}

variable "db_name" {
  description = "Database name to monitor for schema drift"
  type        = string
  default     = "app_core_dev"
}

variable "s3_bucket_name" {
  description = "S3 bucket name for CRDB backups and schema baseline"
  type        = string
  default     = "zero-theft-crdb-backups-stage"
}
