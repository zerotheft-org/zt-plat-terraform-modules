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

variable "crdb_backups_bucket_name" {
  description = "S3 bucket name for CRDB backups"
  type        = string
  default     = "zero-theft-crdb-backups-stage"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
