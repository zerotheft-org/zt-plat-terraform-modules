module "secret_manager" {
  source = "../../../modules/secret_manager"

  environment                 = var.environment
  db_secret_name              = var.db_secret_name
  keycloak_secret_name        = var.keycloak_secret_name
  sendgrid_secret_name        = var.sendgrid_secret_name
  webhook_secret_name         = var.webhook_secret_name

  rotation_schedule_expression = var.rotation_schedule_expression
  rabbitmq_url                = var.rabbitmq_url
  rabbitmq_exchange           = var.rabbitmq_exchange
  rabbitmq_routing_key        = var.rabbitmq_routing_key
  db_admin_user               = var.db_admin_user
  db_admin_password           = var.db_admin_password

  tags = var.tags
}
