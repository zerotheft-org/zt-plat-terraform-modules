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

# -----------------------------------------------------------------------------
# Secret Manager + RabbitMQ
# -----------------------------------------------------------------------------

variable "db_secret_name" {
  description = "Name of the database credentials secret (e.g. stage/app/db-credentials)"
  type        = string
  default     = "stage/app/db-credentials"
}

variable "keycloak_secret_name" {
  description = "Name of the Keycloak client secret (e.g. stage/app/keycloak-client)"
  type        = string
  default     = "stage/app/keycloak-client"
}

variable "sendgrid_secret_name" {
  description = "Name of the SendGrid secret (e.g. stage/app/sendgrid)"
  type        = string
  default     = "stage/app/sendgrid"
}

variable "webhook_secret_name" {
  description = "Name of the webhook/Ngrok secret (e.g. stage/app/webhook)"
  type        = string
  default     = "stage/app/webhook"
}

# credentials used to populate the static secrets
variable "sendgrid_api_key" {
  description = "SendGrid API key"
  type        = string
  sensitive   = true
}

variable "sendgrid_from_email" {
  description = "Sender address used by SendGrid"
  type        = string
}

variable "sendgrid_webhook_verification_key" {
  description = "Verification key for SendGrid webhooks"
  type        = string
  sensitive   = true
}

variable "ngrok_auth_token" {
  description = "Ngrok auth token used by webhook service"
  type        = string
  sensitive   = true
}

variable "rotation_schedule_expression" {
  description = "EventBridge schedule for rotation (e.g. rate(30 days), rate(5 minutes) for testing)"
  type        = string
  default     = "rate(30 days)"
}

variable "rabbitmq_url" {
  description = "RabbitMQ connection URL (amqp://user:pass@host:5672/). Treat this as a secret."
  type        = string
  sensitive   = true
}

variable "rabbitmq_exchange" {
  description = "RabbitMQ topic exchange name"
  type        = string
  default     = "secret-rotation"
}

variable "rabbitmq_routing_key" {
  description = "RabbitMQ routing key (base); section-specific keys are rotation.db, rotation.keycloak"
  type        = string
  default     = "rotation"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "db_admin_user" {
  description = "Admin username for DB rotation"
  type        = string
}

variable "db_admin_password" {
  description = "Admin password for DB rotation"
  type        = string
  sensitive   = true
}
