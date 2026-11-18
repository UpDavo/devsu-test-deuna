data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  via_services = [for s in var.allowed_via_services : "${s}.${local.region}.amazonaws.com"]

  # Acciones de administración. No incluyen operaciones criptográficas:
  # quien administra la llave no puede leer los datos que protege.
  admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListKeyRotations",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RevokeGrant",
    "kms:RotateKeyOnDemand",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
  ]

  crypto_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey*",
    "kms:ReEncrypt*",
  ]
}

data "aws_iam_policy_document" "this" {
  # Statements propios del uso de la llave (por ejemplo, CloudTrail en la
  # llave de auditoría).
  source_policy_documents = var.additional_policy_json != null ? [var.additional_policy_json] : []

  # Sin "kms:*" para root: la cuenta conserva solo la administración como
  # mecanismo de recuperación, y nunca el uso criptográfico.
  statement {
    sid       = "AccountBreakGlassAdministration"
    effect    = "Allow"
    actions   = local.admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = length(var.admin_principal_arns) > 0 ? [1] : []

    content {
      sid       = "KeyAdministrators"
      effect    = "Allow"
      actions   = local.admin_actions
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.admin_principal_arns
      }
    }
  }

  # Uso de la llave solo a través de los servicios declarados y solo por
  # principals de esta cuenta. El acceso efectivo lo decide además la policy
  # IAM del principal y la policy del recurso (bucket, secreto, cluster).
  statement {
    sid       = "UseThroughAllowedServices"
    effect    = "Allow"
    actions   = local.crypto_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = local.via_services
    }
  }

  # Los grants solo se crean para recursos AWS (volúmenes de Aurora, etc.).
  statement {
    sid       = "GrantsForAwsResourcesOnly"
    effect    = "Allow"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = local.via_services
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  dynamic "statement" {
    for_each = length(var.direct_user_principal_arns) > 0 ? [1] : []

    content {
      sid       = "DirectKeyUsers"
      effect    = "Allow"
      actions   = local.crypto_actions
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.direct_user_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = var.allow_cloudwatch_logs ? [1] : []

    content {
      sid       = "CloudWatchLogsEncryption"
      effect    = "Allow"
      actions   = local.crypto_actions
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${local.region}.amazonaws.com"]
      }

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description              = var.description
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  rotation_period_in_days  = var.rotation_period_in_days
  deletion_window_in_days  = var.deletion_window_in_days
  policy                   = data.aws_iam_policy_document.this.json

  tags = merge(var.tags, {
    Name               = var.alias
    DataClassification = var.data_classification
  })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
