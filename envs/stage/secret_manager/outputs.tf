output "db_secret_arn" {
  description = "ARN of the database secret"
  value       = module.secret_manager.db_secret_arn
}

output "db_secret_name" {
  description = "Name of the database secret"
  value       = module.secret_manager.db_secret_name
}

output "lambda_function_name" {
  description = "Name of the rotation Lambda function"
  value       = module.secret_manager.lambda_function_name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge schedule rule"
  value       = module.secret_manager.eventbridge_rule_name
}
