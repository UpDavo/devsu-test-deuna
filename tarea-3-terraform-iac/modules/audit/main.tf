# Auditoría del stack: CloudTrail con evidencia inmutable en S3 y una copia
# en CloudWatch Logs para que la herramienta de observabilidad externa
# alerte sobre los eventos sensibles.
#
# La llave y el bucket son propios, no los del stack de datos: quien
# administra o lee los datos no puede alterar ni leer la evidencia de lo que
# hizo con ellos.

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition

  trail_name = "${var.name}-audit"
  # ARN construido a partir del nombre: la key policy y la bucket policy lo
  # necesitan antes de que exista el trail.
  trail_arn = "arn:${local.partition}:cloudtrail:${var.region}:${var.account_id}:trail/${local.trail_name}"

  log_group_name = "/deuna/audit/${var.name}/cloudtrail"
  log_group_arn  = "arn:${local.partition}:logs:${var.region}:${var.account_id}:log-group:${local.log_group_name}"

  bucket_arn = "arn:${local.partition}:s3:::${var.bucket_name}"

  # Eventos que la herramienta externa debe ver. El resto queda solo en S3,
  # para investigaciones y cumplimiento, sin pagar su ingesta.
  sensitive_events_pattern = join(" || ", [
    # Lectura del secreto de pgadmin (aplicaciones, rotación y break-glass).
    "($.eventSource = \"secretsmanager.amazonaws.com\" && $.eventName = \"GetSecretValue\")",
    # Cambios a la llave: deshabilitar, programar su borrado o cambiar la policy.
    "($.eventSource = \"kms.amazonaws.com\" && ($.eventName = \"DisableKey\" || $.eventName = \"ScheduleKeyDeletion\" || $.eventName = \"PutKeyPolicy\"))",
    # Cambios a la exposición de los buckets.
    "($.eventSource = \"s3.amazonaws.com\" && ($.eventName = \"PutBucketPolicy\" || $.eventName = \"DeleteBucketPolicy\" || $.eventName = \"PutBucketPublicAccessBlock\" || $.eventName = \"DeleteBucketPublicAccessBlock\"))",
    # Intentos de apagar la propia auditoría.
    "($.eventSource = \"cloudtrail.amazonaws.com\" && ($.eventName = \"StopLogging\" || $.eventName = \"DeleteTrail\" || $.eventName = \"UpdateTrail\" || $.eventName = \"PutEventSelectors\"))",
    # Accesos denegados: errores de configuración o alguien probando permisos.
    "($.errorCode = \"AccessDenied*\")",
    # Uso de la cuenta raíz.
    "($.userIdentity.type = \"Root\")",
  ])
}

# --- Llave KMS de auditoría ------------------------------------------------

data "aws_iam_policy_document" "key_cloudtrail" {
  # CloudTrail solo puede cifrar los logs de este trail.
  statement {
    sid       = "CloudTrailEncryptLogs"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${var.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "CloudTrailDescribeKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  # Solo los roles de auditoría pueden descifrar los logs de CloudTrail.
  dynamic "statement" {
    for_each = length(var.reader_principal_arns) > 0 ? [1] : []

    content {
      sid       = "AuditorsDecryptLogs"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.reader_principal_arns
      }

      condition {
        test     = "StringEquals"
        variable = "kms:CallerAccount"
        values   = [var.account_id]
      }

      condition {
        test     = "StringLike"
        variable = "kms:EncryptionContext:aws:cloudtrail:arn"
        values   = ["arn:${local.partition}:cloudtrail:*:${var.account_id}:trail/*"]
      }
    }
  }
}

module "kms" {
  source = "../kms"

  alias                   = "${var.name}-audit"
  description             = "Cifrado de la evidencia de auditoría de ${var.name} (CloudTrail y sus logs)"
  deletion_window_in_days = var.kms_deletion_window_in_days
  admin_principal_arns    = var.admin_principal_arns
  allowed_via_services    = ["s3"]
  allow_cloudwatch_logs   = true
  additional_policy_json  = data.aws_iam_policy_document.key_cloudtrail.json
  data_classification     = "restricted"
  tags                    = var.tags
}

# --- Bucket de evidencia ---------------------------------------------------

data "aws_iam_policy_document" "bucket_cloudtrail" {
  statement {
    sid       = "CloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.bucket_arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/AWSLogs/${var.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  # La evidencia solo la leen los roles de auditoría, aunque otro principal
  # de la cuenta tenga s3:GetObject por IAM.
  dynamic "statement" {
    for_each = length(var.reader_principal_arns) > 0 ? [1] : []

    content {
      sid       = "DenyReadOutsideAuditors"
      effect    = "Deny"
      actions   = ["s3:GetObject", "s3:GetObjectVersion"]
      resources = ["${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = var.reader_principal_arns
      }
    }
  }
}

module "bucket" {
  source = "../s3"

  bucket_name                = var.bucket_name
  kms_key_arn                = module.kms.key_arn
  object_lock_retention_days = var.object_lock_retention_days
  force_destroy              = var.force_destroy
  data_classification        = "restricted"
  additional_policy_json     = data.aws_iam_policy_document.bucket_cloudtrail.json
  # CloudTrail cifra los logs con la llave del trail, pero los archivos digest
  # de la validación de integridad pueden llegar con otras cabeceras de
  # cifrado. Exigir la cabecera de KMS rompería esa validación. El cifrado por
  # defecto del bucket sigue siendo SSE-KMS con la llave de auditoría.
  enforce_kms_headers = false

  lifecycle_rules = {
    transition_ia_days         = 30
    transition_glacier_days    = 90
    expiration_days            = var.retention_days
    noncurrent_expiration_days = 30
  }

  tags = var.tags
}

# --- CloudWatch Logs: canal hacia la herramienta externa -------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = module.kms.key_arn

  tags = var.tags
}

data "aws_iam_policy_document" "cloudtrail_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "cloudtrail_logs" {
  name               = "${var.name}-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name   = "write-audit-log-group"
  role   = aws_iam_role.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}

# Solo los eventos sensibles salen hacia la herramienta externa.
resource "aws_cloudwatch_log_subscription_filter" "sensitive" {
  count = var.log_destination_arn != null ? 1 : 0

  name            = "sensitive-audit-events"
  log_group_name  = aws_cloudwatch_log_group.this.name
  filter_pattern  = "{ ${local.sensitive_events_pattern} }"
  destination_arn = var.log_destination_arn
  role_arn        = var.log_destination_role_arn
}

# --- Trail -----------------------------------------------------------------

resource "aws_cloudtrail" "this" {
  name           = local.trail_name
  s3_bucket_name = module.bucket.bucket_id
  kms_key_id     = module.kms.key_arn

  is_multi_region_trail         = true
  include_global_service_events = true
  # Archivos digest firmados: prueban que ningún log se alteró ni se borró.
  enable_log_file_validation = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.this.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_logs.arn

  # Eventos de administración: incluyen GetSecretValue de Secrets Manager y
  # Decrypt/GenerateDataKey de KMS, es decir, quién leyó el secreto y quién
  # usó la llave de datos.
  advanced_event_selector {
    name = "Management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # Eventos de datos de los buckets del stack: quién leyó o escribió cada
  # objeto. Se cobran por evento, por eso se limitan a estos buckets.
  advanced_event_selector {
    name = "S3 data events"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = [for arn in var.data_bucket_arns : "${arn}/"]
    }

    dynamic "field_selector" {
      for_each = var.log_s3_read_events ? [] : [1]

      content {
        field  = "readOnly"
        equals = ["false"]
      }
    }
  }

  tags = var.tags

  depends_on = [
    module.bucket,
    aws_iam_role_policy.cloudtrail_logs,
  ]
}
