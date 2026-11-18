# Composición de la plataforma de datos: conecta los módulos de servicio
# (kms, s3, aurora, secrets, audit). No declara providers ni backend: eso lo
# hace cada carpeta de environments/.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Rol IAM detrás de la sesión que ejecuta Terraform (el rol del pipeline).
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Los buckets comparten un espacio de nombres global.
  bucket_name = "${local.name_prefix}-data-${var.aws_account_id}-${var.aws_region}"
  bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}"

  # El rol del pipeline entra en la lista porque Terraform lee la versión del
  # secreto en cada refresh. Sin él, el siguiente plan fallaría.
  secret_allowed_arns = distinct(concat(
    var.secret_reader_role_arns,
    [data.aws_iam_session_context.current.issuer_arn],
  ))
}

# Contraseña inicial de pgadmin. Recurso efímero: existe solo durante la
# ejecución y no se escribe en el plan ni en el estado. Secrets Manager la
# reemplaza en la primera rotación.
ephemeral "random_password" "pgadmin" {
  length  = 32
  special = true
  # Caracteres que RDS rechaza o que complican una cadena de conexión.
  override_special = "!#$%^&*()-_=+[]{}"
}

module "kms" {
  source = "../kms"

  alias                   = "${local.name_prefix}-data"
  description             = "Cifrado en reposo de datos de ${local.name_prefix} (S3, Aurora, Secrets Manager)"
  deletion_window_in_days = var.kms_deletion_window_in_days
  admin_principal_arns    = var.kms_admin_role_arns
  allowed_via_services    = ["s3", "rds", "secretsmanager"]
  data_classification     = var.data_classification
}

module "s3" {
  source = "../s3"

  bucket_name                = local.bucket_name
  kms_key_arn                = module.kms.key_arn
  access_log_bucket          = var.s3_access_log_bucket
  lifecycle_rules            = var.s3_lifecycle_rules
  object_lock_retention_days = var.s3_object_lock_retention_days
  force_destroy              = var.s3_force_destroy
  data_classification        = var.data_classification
}

module "aurora" {
  source = "../aurora"

  name                       = "${local.name_prefix}-aurora"
  vpc_id                     = var.vpc_id
  private_subnet_ids         = var.private_subnet_ids
  allowed_security_group_ids = var.app_security_group_ids
  kms_key_arn                = module.kms.key_arn

  engine_version          = var.aurora_engine_version
  master_username         = "pgadmin"
  master_password         = ephemeral.random_password.pgadmin.result
  master_password_version = var.master_password_version

  instance_count     = var.aurora_instance_count
  instance_class     = var.aurora_instance_class
  serverless_scaling = var.aurora_serverless_scaling

  backup_retention_days = var.aurora_backup_retention_days
  deletion_protection   = var.aurora_deletion_protection
  skip_final_snapshot   = var.aurora_skip_final_snapshot

  enhanced_monitoring_interval        = var.aurora_enhanced_monitoring_interval
  performance_insights_retention_days = var.aurora_performance_insights_retention_days
  log_retention_days                  = var.aurora_log_retention_days
}

module "secrets" {
  source = "../secrets"

  name        = "${local.name_prefix}/aurora/pgadmin"
  kms_key_arn = module.kms.key_arn

  username         = module.aurora.master_username
  password         = ephemeral.random_password.pgadmin.result
  password_version = var.master_password_version

  db_host               = module.aurora.endpoint
  db_port               = module.aurora.port
  db_name               = module.aurora.database_name
  db_cluster_identifier = module.aurora.cluster_identifier
  db_security_group_id  = module.aurora.security_group_id

  vpc_id                                    = var.vpc_id
  private_subnet_ids                        = var.private_subnet_ids
  secretsmanager_endpoint_security_group_id = var.secretsmanager_endpoint_security_group_id

  rotation_days           = var.secret_rotation_days
  recovery_window_in_days = var.secret_recovery_window_in_days
  allowed_principal_arns  = local.secret_allowed_arns
}

# Auditoría: CloudTrail con evidencia inmutable en un bucket y una llave
# propios, y una copia filtrada hacia la herramienta de observabilidad.
module "audit" {
  source = "../audit"

  name        = local.name_prefix
  account_id  = var.aws_account_id
  region      = var.aws_region
  bucket_name = "${local.name_prefix}-audit-${var.aws_account_id}-${var.aws_region}"

  data_bucket_arns   = [local.bucket_arn]
  log_s3_read_events = var.audit_log_s3_read_events

  admin_principal_arns        = var.kms_admin_role_arns
  reader_principal_arns       = var.audit_reader_role_arns
  kms_deletion_window_in_days = var.kms_deletion_window_in_days

  retention_days             = var.audit_retention_days
  object_lock_retention_days = var.audit_object_lock_retention_days
  log_retention_days         = var.audit_log_retention_days
  force_destroy              = var.s3_force_destroy

  log_destination_arn      = var.observability_log_destination_arn
  log_destination_role_arn = var.observability_log_destination_role_arn
}
