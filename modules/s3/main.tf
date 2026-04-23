# ---------------------------------------------------------------
# The S3 bucket
# Named clearly so you know it holds CRDB backups for staging
# ---------------------------------------------------------------
resource "aws_s3_bucket" "crdb_backups" {
  bucket = var.bucket_name

  tags = merge(var.tags, {
    Environment = var.environment
    Purpose     = "crdb-backups"
  })
}

# ---------------------------------------------------------------
# Block all public access
# S3 buckets can be accidentally exposed. This is a hard block
# at the bucket level — even if someone adds a public policy,
# this overrides it.
# ---------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------
# AES-256 encryption at rest (SSE-S3)
# Every object stored in this bucket is encrypted automatically.
# SSE-S3 uses Amazon-managed keys — no extra cost, no KMS needed.
# ---------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------
# Enforce bucket owner control — disables legacy ACLs
# AWS deprecated object ACLs. This enforces IAM-only access control.
# ---------------------------------------------------------------
resource "aws_s3_bucket_ownership_controls" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ---------------------------------------------------------------
# Enforce TLS-only access to backup objects.
# Denies any request made over insecure transport.
# ---------------------------------------------------------------
data "aws_iam_policy_document" "crdb_backups_tls_only" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.crdb_backups.arn,
      "${aws_s3_bucket.crdb_backups.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "crdb_backups_tls_only" {
  bucket = aws_s3_bucket.crdb_backups.id
  policy = data.aws_iam_policy_document.crdb_backups_tls_only.json
}

# ---------------------------------------------------------------
# Versioning
# Keeps previous versions of backup files.
# If a backup is accidentally overwritten or corrupted,
# you can restore the previous version.
# ---------------------------------------------------------------
resource "aws_s3_bucket_versioning" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------
# Lifecycle rule — auto-expire old backups
# Without this, S3 storage grows forever and costs money.
# Backups under the "backups/" prefix expire after 90 days.
# Old versions (from versioning) expire after 30 days.
# Adjust days to match your retention requirements.
# ---------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  depends_on = [aws_s3_bucket_versioning.crdb_backups]

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------
# IAM Policy Document
# Defines what S3 actions are allowed. This is just a JSON
# definition — not attached to anything until the next two blocks.
# ---------------------------------------------------------------
data "aws_iam_policy_document" "crdb_s3_access" {
  statement {
    sid    = "AllowCRDBBackupRestore"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [
      aws_s3_bucket.crdb_backups.arn,
      "${aws_s3_bucket.crdb_backups.arn}/*",
    ]
  }
}

# ---------------------------------------------------------------
# IAM Policy
# Wraps the policy document into a named, reusable AWS policy.
# ---------------------------------------------------------------
resource "aws_iam_policy" "crdb_s3_access" {
  name        = "crdb-s3-backup-access-${var.environment}"
  description = "Allow read/write access to CRDB backup S3 bucket"
  policy      = data.aws_iam_policy_document.crdb_s3_access.json

  tags = var.tags
}

# ---------------------------------------------------------------
# ---------------------------------------------------------------
# IAM Role — reserved for future use (e.g., EC2-based services
# or automated backup agents that need S3 access).
# Current CRDB backups use crdb-backup-agent-stage IAM user instead.
# See: stage/app/crdb-backup-agent in Secrets Manager.
# ---------------------------------------------------------------
resource "aws_iam_role" "crdb_backup_role" {
  name = "crdb-backup-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# ---------------------------------------------------------------
# Attach the policy to the role
# Without this, the role exists but has no permissions.
# ---------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "crdb_backup_role" {
  role       = aws_iam_role.crdb_backup_role.name
  policy_arn = aws_iam_policy.crdb_s3_access.arn
}
