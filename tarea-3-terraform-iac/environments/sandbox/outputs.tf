output "kms_key_arn" {
  description = "ARN de la llave KMS de datos."
  value       = module.data_platform.kms_key_arn
}

output "kms_alias" {
  description = "Alias de la llave KMS de datos."
  value       = module.data_platform.kms_alias
}

output "s3_bucket_name" {
  description = "Nombre del bucket de datos."
  value       = module.data_platform.s3_bucket_name
}

output "aurora_endpoint" {
  description = "Endpoint de escritura de Aurora."
  value       = module.data_platform.aurora_endpoint
}

output "aurora_reader_endpoint" {
  description = "Endpoint de lectura de Aurora."
  value       = module.data_platform.aurora_reader_endpoint
}

output "aurora_security_group_id" {
  description = "Security group del cluster Aurora."
  value       = module.data_platform.aurora_security_group_id
}

output "pgadmin_secret_arn" {
  description = "ARN del secreto con las credenciales de pgadmin."
  value       = module.data_platform.pgadmin_secret_arn
}

output "audit_trail_arn" {
  description = "ARN del trail de auditoría."
  value       = module.data_platform.audit_trail_arn
}

output "audit_bucket_name" {
  description = "Bucket con la evidencia de auditoría."
  value       = module.data_platform.audit_bucket_name
}

output "audit_log_group_name" {
  description = "Log group de auditoría que ingiere la herramienta de observabilidad."
  value       = module.data_platform.audit_log_group_name
}
