data "aws_partition" "current" {}

locals {
  # ARN derivado del nombre: la bucket policy queda resuelta desde el plan
  # y se puede revisar completa antes del apply.
  bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}"
}

resource "aws_s3_bucket" "this" {
  bucket              = var.bucket_name
  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock_retention_days != null

  tags = merge(var.tags, {
    Name               = var.bucket_name
    DataClassification = var.data_classification
  })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deshabilita las ACL: el acceso se controla solo con policies.
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    # Bucket Key reduce las llamadas a KMS y su costo en cargas de alto volumen.
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

# Publica los eventos de objetos en EventBridge. No tiene costo hasta que una
# regla los consuma (auditoría, alertas, pipelines de datos).
resource "aws_s3_bucket_notification" "this" {
  bucket      = aws_s3_bucket.this.id
  eventbridge = true
}

resource "aws_s3_bucket_logging" "this" {
  count = var.access_log_bucket != null ? 1 : 0

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_log_bucket
  target_prefix = "s3-access/${var.bucket_name}/"
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  count = var.object_lock_retention_days != null ? 1 : 0

  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "tiering-and-retention"
    status = "Enabled"

    filter {}

    transition {
      days          = var.lifecycle_rules.transition_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.lifecycle_rules.transition_glacier_days
      storage_class = "GLACIER_IR"
    }

    dynamic "expiration" {
      for_each = var.lifecycle_rules.expiration_days != null ? [1] : []

      content {
        days = var.lifecycle_rules.expiration_days
      }
    }

    noncurrent_version_transition {
      noncurrent_days = var.lifecycle_rules.noncurrent_transition_days
      storage_class   = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days           = var.lifecycle_rules.noncurrent_expiration_days
      newer_noncurrent_versions = var.lifecycle_rules.noncurrent_versions_to_keep
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.lifecycle_rules.abort_incomplete_multipart_in_days
    }
  }

  # Limpia los delete markers huérfanos que deja el versionado.
  rule {
    id     = "expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "this" {
  # Statements propios del uso del bucket (por ejemplo, la escritura de
  # CloudTrail en el bucket de auditoría).
  source_policy_documents = var.additional_policy_json != null ? [var.additional_policy_json] : []

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyOutdatedTls"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }

  # IfExists: una carga sin cabeceras usa el cifrado por defecto del bucket.
  # Una carga que pida otro algoritmo u otra llave se rechaza.
  dynamic "statement" {
    for_each = var.enforce_kms_headers ? [1] : []

    content {
      sid       = "DenyNonKmsEncryption"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEqualsIfExists"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enforce_kms_headers ? [1] : []

    content {
      sid       = "DenyWrongKmsKey"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEqualsIfExists"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = [var.kms_key_arn]
      }
    }
  }

  # Con BucketOwnerEnforced un cambio de ACL nunca es legítimo.
  statement {
    sid       = "DenyAclChanges"
    effect    = "Deny"
    actions   = ["s3:PutBucketAcl", "s3:PutObjectAcl", "s3:PutObjectVersionAcl"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
