# Sandbox: misma topología que producción (dos instancias, failover) a menor
# capacidad. Es el ensayo general antes de promover un cambio.
# Los identificadores de cuenta y de red son marcadores: reemplazar por los reales.

locals {
  environment    = "sandbox"
  aws_account_id = "222222222222"
  aws_region     = "us-east-1"
}

module "data_platform" {
  source = "../../modules/data-platform"

  environment    = local.environment
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region

  data_classification = "internal"

  vpc_id                 = "vpc-0sbx00000000000000"
  private_subnet_ids     = ["subnet-0sbx0000000000000a", "subnet-0sbx0000000000000b"]
  app_security_group_ids = ["sg-0sbx00000000000000"]

  secretsmanager_endpoint_security_group_id = "sg-0sbx0000000000vpce"

  kms_deletion_window_in_days = 7

  s3_lifecycle_rules = {
    expiration_days            = 180
    noncurrent_expiration_days = 60
  }

  aurora_instance_count        = 2
  aurora_serverless_scaling    = { min_capacity = 0.5, max_capacity = 4 }
  aurora_backup_retention_days = 7
  aurora_deletion_protection   = false
  aurora_skip_final_snapshot   = true
  aurora_log_retention_days    = 30

  secret_recovery_window_in_days = 7

  # Auditoría: solo escrituras en S3; evidencia inmutable un año.
  audit_log_s3_read_events         = false
  audit_retention_days             = 365
  audit_object_lock_retention_days = 365
  audit_log_retention_days         = 90
}
