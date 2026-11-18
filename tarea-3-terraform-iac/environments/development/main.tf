# Development: costo mínimo y recursos descartables.
# Los identificadores de cuenta y de red son marcadores: reemplazar por los reales.

locals {
  environment    = "development"
  aws_account_id = "111111111111"
  aws_region     = "us-east-1"
}

module "data_platform" {
  source = "../../modules/data-platform"

  environment    = local.environment
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region

  data_classification = "internal"

  vpc_id                 = "vpc-0dev00000000000000"
  private_subnet_ids     = ["subnet-0dev0000000000000a", "subnet-0dev0000000000000b"]
  app_security_group_ids = ["sg-0dev00000000000000"]

  secretsmanager_endpoint_security_group_id = "sg-0dev0000000000vpce"

  kms_deletion_window_in_days = 7

  s3_force_destroy = true
  s3_lifecycle_rules = {
    expiration_days            = 90
    noncurrent_expiration_days = 30
  }

  # Serverless v2 con piso de 0.5 ACU: una sola instancia, paga por uso.
  aurora_instance_count        = 1
  aurora_serverless_scaling    = { min_capacity = 0.5, max_capacity = 2 }
  aurora_backup_retention_days = 1
  aurora_deletion_protection   = false
  aurora_skip_final_snapshot   = true
  aurora_log_retention_days    = 14

  secret_recovery_window_in_days = 7

  # Auditoría: sin Object Lock (ambiente descartable) y solo escrituras en S3.
  audit_log_s3_read_events         = false
  audit_retention_days             = 90
  audit_object_lock_retention_days = null
  audit_log_retention_days         = 30
}
