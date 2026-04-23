variable "environment" {
  description = "Environment name"
  type        = string

  validation {
    condition     = length(trimspace(var.environment)) > 0
    error_message = "environment must not be empty."
  }
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket to monitor for drift"
  type        = string

  validation {
    condition     = length(trimspace(var.s3_bucket_name)) > 0
    error_message = "s3_bucket_name must not be empty."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "crdb_secret_name" {
  description = "Secrets Manager secret name containing CRDB connection details"
  type        = string

  validation {
    condition     = length(trimspace(var.crdb_secret_name)) > 0
    error_message = "crdb_secret_name must not be empty."
  }
}

variable "db_name" {
  description = "Database name to monitor for schema drift"
  type        = string

  validation {
    condition     = length(trimspace(var.db_name)) > 0
    error_message = "db_name must not be empty."
  }
}

variable "alarm_topic_arn" {
  description = "Optional SNS topic ARN for schema drift alarm notifications"
  type        = string
  default     = ""
}

variable "config_logs_force_destroy" {
  description = "Allow force-destroy of Config log bucket"
  type        = bool
  default     = false
}
