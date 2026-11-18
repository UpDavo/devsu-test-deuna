# Production: datos financieros reales. Máxima retención y protección.
# Los identificadores de cuenta, red y roles son marcadores: reemplazar por los reales.

locals {
  environment    = "production"
  aws_account_id = "333333333333"
  aws_region     = "us-east-1"
}

module "data_platform" {
  source = "../../modules/data-platform"

  environment    = local.environment
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region

  data_classification = "restricted"

  vpc_id                 = "vpc-0prd00000000000000"
  private_subnet_ids     = ["subnet-0prd0000000000000a", "subnet-0prd0000000000000b", "subnet-0prd0000000000000c"]
  app_security_group_ids = ["sg-0prd00000000000000"]

  secretsmanager_endpoint_security_group_id = "sg-0prd0000000000vpce"

  kms_admin_role_arns     = ["arn:aws:iam::333333333333:role/security-kms-admin"]
  secret_reader_role_arns = ["arn:aws:iam::333333333333:role/dba-break-glass"]

  kms_deletion_window_in_days = 30

  s3_access_log_bucket          = "deuna-production-access-logs-333333333333-us-east-1"
  s3_object_lock_retention_days = 2555 # 7 años de retención inmutable
  s3_lifecycle_rules = {
    transition_ia_days          = 30
    transition_glacier_days     = 90
    noncurrent_expiration_days  = 2555
    noncurrent_versions_to_keep = 10
  }

  # Aprovisionado sobre Graviton: carga estable y predecible, apta para
  # Reserved Instances. Tres instancias en tres zonas.
  aurora_instance_count                      = 3
  aurora_instance_class                      = "db.r6g.xlarge"
  aurora_backup_retention_days               = 35
  aurora_deletion_protection                 = true
  aurora_skip_final_snapshot                 = false
  aurora_enhanced_monitoring_interval        = 15
  aurora_performance_insights_retention_days = 31
  aurora_log_retention_days                  = 365

  # Auditoría: lecturas y escrituras del bucket de datos; evidencia inmutable
  # siete años, igual que los datos.
  audit_reader_role_arns           = ["arn:aws:iam::333333333333:role/security-auditor"]
  audit_log_s3_read_events         = true
  audit_retention_days             = 2555
  audit_object_lock_retention_days = 2555
  audit_log_retention_days         = 365

  secret_rotation_days           = 30
  secret_recovery_window_in_days = 30
}
