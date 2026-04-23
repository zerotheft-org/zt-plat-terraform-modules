variable "environment" {
  description = "Environment name (e.g. stage, production). Used only for naming."
  type        = string
}

variable "db_secret_name" {
  description = "Name of the database credentials secret (e.g. stage/app/db-credentials)"
  type        = string
}

variable "keycloak_secret_name" {
  description = "Name of the Keycloak client secret (e.g. stage/app/keycloak-client)"
  type        = string
}

variable "sendgrid_secret_name" {
  description = "Name of the SendGrid secret (e.g. stage/app/sendgrid)"
  type        = string
}

variable "webhook_secret_name" {
  description = "Name of the webhook/ngrok secret (e.g. stage/app/webhook)"
  type        = string
}

variable "rotation_schedule_expression" {
  description = "EventBridge schedule expression for rotation (e.g. rate(30 days))"
  type        = string
  default     = "rate(30 days)"
}

variable "rabbitmq_url" {
  description = "RabbitMQ connection URL (amqp://user:pass@host:5672/). Treat this as a secret."
  type        = string
  sensitive   = true
}

variable "rabbitmq_exchange" {
  description = "RabbitMQ topic exchange name to publish rotation events to"
  type        = string
  default     = "secret-rotation"
}

variable "rabbitmq_routing_key" {
  description = "RabbitMQ routing key base for rotation events (payload indicates which sections updated)"
  type        = string
  default     = "rotation"
}

variable "keycloak_rotation_grace_days" {
  description = "Rotate Keycloak client_secret only when expires_at is within this many days (or past)"
  type        = number
  default     = 7
}

variable "db_admin_user" {
  description = "Username the rotation Lambda uses to connect as an admin to the database"
  type        = string
}

variable "db_admin_password" {
  description = "Password for the admin user used by the rotation Lambda"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}
