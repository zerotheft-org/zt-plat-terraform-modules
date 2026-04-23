data "aws_caller_identity" "current" {}
data "aws_secretsmanager_secret" "crdb" {
  name = var.crdb_secret_name
}

# ---------------------------------------------------------------
# S3 bucket for Config to store its snapshots
# Config requires a delivery destination to function.
# This is NOT your backup bucket — it's Config's own storage.
# ---------------------------------------------------------------
resource "aws_s3_bucket" "config_logs" {
  bucket        = "zero-theft-config-logs-${var.environment}"
  force_destroy = var.config_logs_force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "config_logs" {
  bucket                  = aws_s3_bucket.config_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------
# Bucket policy — Config needs explicit permission to write here.
# Without this the recorder starts but delivery fails silently.
# ---------------------------------------------------------------
resource "aws_s3_bucket_policy" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config_logs.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------
# IAM role for Config — needs read access to evaluate resources
# ---------------------------------------------------------------
resource "aws_iam_role" "config" {
  name = "aws-config-drift-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# ---------------------------------------------------------------
# Config recorder — scoped to S3 only
# all_supported = false means we only record what we list.
# Recording everything costs money and slows evaluations.
# ---------------------------------------------------------------
resource "aws_config_configuration_recorder" "main" {
  name     = "drift-recorder-${var.environment}"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported = false
    resource_types = [
      "AWS::S3::Bucket",
      "AWS::S3::AccountPublicAccessBlock",
    ]
  }
}

# ---------------------------------------------------------------
# Delivery channel — required for recorder to start
# No SNS topic — snapshots go to S3 only
# ---------------------------------------------------------------
resource "aws_config_delivery_channel" "main" {
  name           = "drift-delivery-${var.environment}"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket

  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# ---------------------------------------------------------------
# Start the recorder
# Created stopped by default — this explicitly enables it
# ---------------------------------------------------------------
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# ---------------------------------------------------------------
# Rule 1: Encryption at rest must be enabled
# NON_COMPLIANT if someone disables AES-256 on the bucket
# ---------------------------------------------------------------
resource "aws_config_config_rule" "s3_encryption" {
  name        = "s3-backup-bucket-encrypted-${var.environment}"
  description = "S3 backup bucket must have server-side encryption enabled"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
    compliance_resource_id    = var.s3_bucket_name
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ---------------------------------------------------------------
# Rule 2: Public access must be blocked
# NON_COMPLIANT if anyone enables public access on the bucket
# ---------------------------------------------------------------
resource "aws_config_config_rule" "s3_public_access_blocked" {
  name        = "s3-backup-bucket-no-public-access-${var.environment}"
  description = "S3 backup bucket must have public access blocked"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
    compliance_resource_id    = var.s3_bucket_name
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ---------------------------------------------------------------
# Rule 3: Versioning must be enabled
# NON_COMPLIANT if versioning is suspended on the bucket
# ---------------------------------------------------------------
resource "aws_config_config_rule" "s3_versioning" {
  name        = "s3-backup-bucket-versioning-enabled-${var.environment}"
  description = "S3 backup bucket must have versioning enabled"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_VERSIONING_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
    compliance_resource_id    = var.s3_bucket_name
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ---------------------------------------------------------------
# CloudWatch Log Group for the Lambda
# Explicit declaration gives us control over retention.
# Without this block AWS creates it automatically with no expiry.
# ---------------------------------------------------------------
resource "aws_cloudwatch_log_group" "schema_drift" {
  name              = "/aws/lambda/crdb-schema-drift-${var.environment}"
  retention_in_days = 30
  tags              = var.tags
}

# ---------------------------------------------------------------
# Metric Filter
# Watches Lambda logs for the string SCHEMA_DRIFT_DETECTED.
# When found, increments a counter in CloudWatch Metrics.
# ---------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "schema_drift" {
  name           = "crdb-schema-drift-detected-${var.environment}"
  log_group_name = aws_cloudwatch_log_group.schema_drift.name
  pattern        = "SCHEMA_DRIFT_DETECTED"

  metric_transformation {
    name      = "CRDBSchemaDriftCount"
    namespace = "ZeroTheft/${var.environment}"
    value     = "1"
  }

  depends_on = [aws_cloudwatch_log_group.schema_drift]
}

# ---------------------------------------------------------------
# CloudWatch Alarm
# Fires when drift counter >= 1 within a 7-day window.
# period = 604800 matches the weekly Lambda schedule.
# treat_missing_data = notBreaching means no alarm if Lambda
# did not run yet (e.g. waiting for first Monday).
# ---------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "schema_drift" {
  alarm_name          = "crdb-schema-drift-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CRDBSchemaDriftCount"
  namespace           = "ZeroTheft/${var.environment}"
  period              = 604800
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "CRDB schema drift detected in ${var.environment}"
  alarm_actions       = var.alarm_topic_arn != "" ? [var.alarm_topic_arn] : []
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ---------------------------------------------------------------
# IAM Role for the Lambda
# Three permissions only:
#   - Read/write the schema-baseline prefix in S3
#   - Read the CRDB secret from Secrets Manager
#   - Write logs to CloudWatch
# ---------------------------------------------------------------
resource "aws_iam_role" "schema_drift_lambda" {
  name = "crdb-schema-drift-lambda-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "schema_drift_lambda" {
  name = "crdb-schema-drift-lambda-policy-${var.environment}"
  role = aws_iam_role.schema_drift_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BaselineReadWrite"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/schema-baseline/*"
      },
      {
        Sid      = "S3BucketList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.s3_bucket_name}"
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = [
          data.aws_secretsmanager_secret.crdb.arn,
          "${data.aws_secretsmanager_secret.crdb.arn}*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.schema_drift.arn,
          "${aws_cloudwatch_log_group.schema_drift.arn}:*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------
# Lambda Function
# DB_NAME comes from var.db_name — passed by the caller.
# The module itself has no opinion on what database to monitor.
# ---------------------------------------------------------------
resource "aws_lambda_function" "schema_drift" {
  filename         = "${path.module}/lambda/schema_drift.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/schema_drift.zip")
  function_name    = "crdb-schema-drift-${var.environment}"
  role             = aws_iam_role.schema_drift_lambda.arn
  handler          = "schema_drift.handler"
  runtime          = "python3.11"
  timeout          = 30

  environment {
    variables = {
      DB_SECRET_NAME  = var.crdb_secret_name
      DB_NAME         = var.db_name
      S3_BUCKET       = var.s3_bucket_name
      S3_BASELINE_KEY = "schema-baseline/schema_snapshot.json"
      ENVIRONMENT     = var.environment
    }
  }

  depends_on = [aws_cloudwatch_log_group.schema_drift]

  tags = var.tags
}

# ---------------------------------------------------------------
# EventBridge Rule — triggers Lambda once a week
# cron(0 8 ? * MON *) = every Monday at 8am UTC
# ---------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "schema_drift" {
  name                = "crdb-schema-drift-schedule-${var.environment}"
  description         = "Weekly CRDB schema drift check for ${var.environment}"
  schedule_expression = "cron(0 8 ? * MON *)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "schema_drift" {
  rule      = aws_cloudwatch_event_rule.schema_drift.name
  target_id = "SchemaDriftLambda"
  arn       = aws_lambda_function.schema_drift.arn
}

resource "aws_lambda_permission" "schema_drift" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.schema_drift.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schema_drift.arn
}
