output "config_recorder_name" {
  description = "Name of the AWS Config recorder"
  value       = aws_config_configuration_recorder.main.name
}

output "config_rule_names" {
  description = "All Config rule names — use these in the drift check CLI command"
  value = [
    aws_config_config_rule.s3_encryption.name,
    aws_config_config_rule.s3_public_access_blocked.name,
    aws_config_config_rule.s3_versioning.name,
  ]
}

output "config_logs_bucket" {
  description = "S3 bucket where Config stores snapshots"
  value       = aws_s3_bucket.config_logs.bucket
}

output "schema_drift_lambda_name" {
  description = "Lambda function name for schema drift detection"
  value       = aws_lambda_function.schema_drift.function_name
}

output "schema_drift_alarm_name" {
  description = "CloudWatch alarm name for schema drift"
  value       = aws_cloudwatch_metric_alarm.schema_drift.alarm_name
}