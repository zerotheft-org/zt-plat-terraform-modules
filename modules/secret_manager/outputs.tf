output "db_secret_arn" {
  description = "ARN of the DB secret"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Name of the DB secret"
  value       = aws_secretsmanager_secret.db.name
}

output "keycloak_secret_arn" {
  description = "ARN of the Keycloak secret"
  value       = aws_secretsmanager_secret.keycloak.arn
}

output "keycloak_secret_name" {
  description = "Name of the Keycloak secret"
  value       = aws_secretsmanager_secret.keycloak.name
}

output "sendgrid_secret_arn" {
  description = "ARN of the SendGrid secret"
  value       = aws_secretsmanager_secret.sendgrid.arn
}

output "sendgrid_secret_name" {
  description = "Name of the SendGrid secret"
  value       = aws_secretsmanager_secret.sendgrid.name
}

output "webhook_secret_arn" {
  description = "ARN of the Webhook secret"
  value       = aws_secretsmanager_secret.webhook.arn
}

output "webhook_secret_name" {
  description = "Name of the Webhook secret"
  value       = aws_secretsmanager_secret.webhook.name
}

output "lambda_function_name" {
  description = "Name of the rotation + notification Lambda function"
  value       = aws_lambda_function.rotation_notifier.function_name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge schedule rule"
  value       = aws_cloudwatch_event_rule.rotation_schedule.name
}
