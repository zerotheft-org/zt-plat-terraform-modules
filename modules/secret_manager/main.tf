locals {
  lambda_function_name = "secret-rotation-notifier-${var.environment}"
}

# AWS Secrets Manager — separate secrets per responsibility

# DB secret (rotated by the lambda)
resource "aws_secretsmanager_secret" "db" {
  name        = var.db_secret_name
  description = "Database credentials for ${var.environment} (rotated by lambda)"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "db_initial" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    db={
    host       = "host-url",
    port       = 26257,
    database   = "defaultdb",
    active_user = "A",
    users = {
      A = { username = "user_a", password = "your-pw", expires_at = null }
      B = { username = "user_b", password = "your-pw", expires_at = null }
    }
  }
  }
  )
}

# Keycloak client (stored here; rotation not performed unless you enable it)
resource "aws_secretsmanager_secret" "keycloak" {
  name        = var.keycloak_secret_name
  description = "Keycloak client credentials for ${var.environment}"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "keycloak_initial" {
  secret_id     = aws_secretsmanager_secret.keycloak.id
  secret_string = jsonencode({
    client_id     = "client-id",
    client_secret = "client-secret",
    expires_at    = null
  })
}

# SendGrid (static credential)
resource "aws_secretsmanager_secret" "sendgrid" {
  name        = var.sendgrid_secret_name
  description = "SendGrid credentials for ${var.environment}"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "sendgrid_initial" {
  secret_id     = aws_secretsmanager_secret.sendgrid.id
  secret_string = jsonencode({
    from_email               = "email",
    api_key                  = "key",
    webhook_verification_key = "key"
  })
}

# Webhook / ngrok
resource "aws_secretsmanager_secret" "webhook" {
  name        = var.webhook_secret_name
  description = "Webhook / ngrok credentials for ${var.environment}"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "webhook_initial" {
  secret_id     = aws_secretsmanager_secret.webhook.id
  secret_string = jsonencode({ ngrok = { auth_token = "key", expires_at = null } })
}

# IAM Role for Lambda

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "secret-rotation-notifier-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    effect = "Allow"

    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue"
    ]

    resources = [
      aws_secretsmanager_secret.db.arn
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/${local.lambda_function_name}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "secret-rotation-notifier-policy-${var.environment}"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# Lambda Function (rotate secret + publish to RabbitMQ)


resource "aws_lambda_function" "rotation_notifier" {
  filename         = "${path.module}/lambda_rotation.zip"
  function_name    = local.lambda_function_name
  role             = aws_iam_role.lambda.arn
  handler          = "rotation_handler.lambda_handler"
  source_code_hash = filebase64sha256("${path.module}/lambda_rotation.zip")
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      SECRET_ID               = aws_secretsmanager_secret.db.id
      RABBITMQ_URL            = var.rabbitmq_url
      RABBITMQ_EXCHANGE       = var.rabbitmq_exchange
      RABBITMQ_ROUTING_KEY    = var.rabbitmq_routing_key
      KEYCLOAK_GRACE_DAYS     = tostring(var.keycloak_rotation_grace_days)
      DB_ADMIN_USER           = var.db_admin_user
      DB_ADMIN_PASSWORD       = var.db_admin_password
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda
  ]

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = 30

  tags = var.tags
}

# EventBridge Rule -> Lambda

resource "aws_cloudwatch_event_rule" "rotation_schedule" {
  name                = "secret-rotation-schedule-${var.environment}"
  description         = "Schedule for rotating secret and broadcasting to RabbitMQ"
  schedule_expression = var.rotation_schedule_expression

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "rotation_target" {
  rule      = aws_cloudwatch_event_rule.rotation_schedule.name
  target_id = "InvokeLambda"
  arn       = aws_lambda_function.rotation_notifier.arn
}

resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotation_schedule.arn
}
