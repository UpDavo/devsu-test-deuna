data "aws_partition" "current" {}

locals {
  is_serverless = var.serverless_scaling != null
}

# --- Red -------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Subnets privadas del cluster ${var.name}"
  subnet_ids  = var.private_subnet_ids

  tags = merge(var.tags, { Name = var.name })
}

# Sin reglas inline ni egress: la base no inicia conexiones salientes.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "Acceso al cluster Aurora ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "apps" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
  description                  = "PostgreSQL desde ${each.value}"

  tags = var.tags
}

# --- Parámetros ------------------------------------------------------------

resource "aws_rds_cluster_parameter_group" "this" {
  name        = var.name
  family      = var.parameter_group_family
  description = "Parametros del cluster ${var.name}"

  # Rechaza conexiones sin TLS.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.slow_query_threshold_ms)
  }

  # DDL en el log estándar. Las sentencias de datos no se registran:
  # expondrían información financiera en los logs.
  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pgaudit"
    apply_method = "pending-reboot"
  }

  # Auditoría de DDL y de cambios de roles y permisos.
  parameter {
    name  = "pgaudit.log"
    value = "ddl,role"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# --- Observabilidad --------------------------------------------------------

# Se crea antes que el cluster para fijar retención y cifrado. Si RDS lo
# creara por su cuenta quedaría sin expiración y sin llave propia.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/cluster/${var.name}/postgresql"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.enhanced_monitoring_interval > 0 ? 1 : 0

  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.enhanced_monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- Cluster ---------------------------------------------------------------

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = var.engine_version
  database_name      = var.database_name
  port               = var.port

  master_username = var.master_username
  # Write-only: el valor llega a la API pero no queda en el plan ni en el estado.
  master_password_wo         = var.master_password
  master_password_wo_version = var.master_password_version

  iam_database_authentication_enabled = true

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.this.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window
  copy_tags_to_snapshot        = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  dynamic "serverlessv2_scaling_configuration" {
    for_each = local.is_serverless ? [var.serverless_scaling] : []

    content {
      min_capacity = serverlessv2_scaling_configuration.value.min_capacity
      max_capacity = serverlessv2_scaling_configuration.value.max_capacity
    }
  }

  tags = merge(var.tags, { Name = var.name })

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "${var.name}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = local.is_serverless ? "db.serverless" : var.instance_class

  db_subnet_group_name       = aws_db_subnet_group.this.name
  publicly_accessible        = false
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = var.performance_insights_retention_days

  monitoring_interval = var.enhanced_monitoring_interval
  monitoring_role_arn = var.enhanced_monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  tags = merge(var.tags, { Name = "${var.name}-${count.index + 1}" })

  depends_on = [aws_iam_role_policy_attachment.monitoring]
}
