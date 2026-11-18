data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  partition     = data.aws_partition.current.partition
  region        = data.aws_region.current.region
  function_name = "${replace(var.name, "/", "-")}-rotation"

  # Aplicación oficial de AWS para rotar un usuario de RDS PostgreSQL.
  rotation_app_arn = "arn:${local.partition}:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser"

  # Principals con acceso al valor: los declarados y la Lambda de rotación.
  value_access_arns = concat(var.allowed_principal_arns, [data.aws_lambda_function.rotation.role])
}

# --- Secreto ---------------------------------------------------------------

resource "aws_secretsmanager_secret" "this" {
  name                    = var.name
  description             = var.description
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, { Name = var.name })
}

# Write-only: el valor inicial llega a la API pero no queda en el plan ni en
# el estado. Las versiones siguientes las escribe la Lambda de rotación.
resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  secret_string_wo = jsonencode({
    engine              = "postgres"
    host                = var.db_host
    port                = var.db_port
    dbname              = var.db_name
    dbClusterIdentifier = var.db_cluster_identifier
    username            = var.username
    password            = var.password
  })
  secret_string_wo_version = var.password_version
}

# --- Resource policy -------------------------------------------------------

data "aws_iam_policy_document" "this" {
  # Deny explícito: gana sobre cualquier Allow de IAM, incluso de
  # administradores de la cuenta que no estén en la lista.
  statement {
    sid    = "DenyValueAccessOutsideAllowList"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.this.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.value_access_arns
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["secretsmanager:*"]
    resources = [aws_secretsmanager_secret.this.arn]

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
}

resource "aws_secretsmanager_secret_policy" "this" {
  secret_arn          = aws_secretsmanager_secret.this.arn
  policy              = data.aws_iam_policy_document.this.json
  block_public_policy = true
}

# --- Rotación automática ---------------------------------------------------

resource "aws_security_group" "rotation" {
  # checkov:skip=CKV2_AWS_5:El grupo se asocia a la Lambda mediante el parámetro vpcSecurityGroupIds del stack de rotación
  name        = local.function_name
  description = "Lambda de rotacion del secreto ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = local.function_name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "rotation_to_db" {
  security_group_id            = aws_security_group.rotation.id
  referenced_security_group_id = var.db_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  description                  = "PostgreSQL hacia el cluster"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "rotation_to_api" {
  # Sin salida a internet: la Lambda llega a la API solo por el VPC endpoint.
  security_group_id            = aws_security_group.rotation.id
  referenced_security_group_id = var.secretsmanager_endpoint_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS hacia el VPC endpoint de Secrets Manager"

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_rotation" {
  security_group_id            = var.db_security_group_id
  referenced_security_group_id = aws_security_group.rotation.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  description                  = "PostgreSQL desde la Lambda de rotacion"

  tags = var.tags
}

data "aws_serverlessapplicationrepository_application" "rotation" {
  application_id   = local.rotation_app_arn
  semantic_version = var.rotation_app_semantic_version
}

resource "aws_serverlessapplicationrepository_cloudformation_stack" "rotation" {
  name             = local.function_name
  application_id   = data.aws_serverlessapplicationrepository_application.rotation.application_id
  semantic_version = data.aws_serverlessapplicationrepository_application.rotation.semantic_version
  capabilities     = data.aws_serverlessapplicationrepository_application.rotation.required_capabilities

  parameters = {
    endpoint            = "https://secretsmanager.${local.region}.amazonaws.com"
    functionName        = local.function_name
    kmsKeyArn           = var.kms_key_arn
    vpcSubnetIds        = join(",", var.private_subnet_ids)
    vpcSecurityGroupIds = aws_security_group.rotation.id
  }

  tags = var.tags
}

# Rol de ejecución de la Lambda, para incluirlo en la resource policy.
data "aws_lambda_function" "rotation" {
  function_name = local.function_name

  depends_on = [aws_serverlessapplicationrepository_cloudformation_stack.rotation]
}

resource "aws_secretsmanager_secret_rotation" "this" {
  secret_id           = aws_secretsmanager_secret.this.id
  rotation_lambda_arn = aws_serverlessapplicationrepository_cloudformation_stack.rotation.outputs["RotationLambdaARN"]

  rotation_rules {
    automatically_after_days = var.rotation_days
  }

  # La primera rotación corre al crear el recurso: necesita el valor inicial,
  # la policy y la ruta de red ya en su sitio.
  depends_on = [
    aws_secretsmanager_secret_version.this,
    aws_secretsmanager_secret_policy.this,
    aws_vpc_security_group_ingress_rule.db_from_rotation,
    aws_vpc_security_group_egress_rule.rotation_to_db,
    aws_vpc_security_group_egress_rule.rotation_to_api,
  ]
}
