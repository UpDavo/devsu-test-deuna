output "kms_key_arn" {
  description = "ARN de la llave KMS de datos."
  value       = module.kms.key_arn
}

output "kms_alias" {
  description = "Alias de la llave KMS de datos."
  value       = module.kms.alias_name
}

output "s3_bucket_name" {
  description = "Nombre del bucket de datos."
  value       = module.s3.bucket_id
}

output "aurora_endpoint" {
  description = "Endpoint de escritura de Aurora."
  value       = module.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Endpoint de lectura de Aurora."
  value       = module.aurora.reader_endpoint
}

output "aurora_security_group_id" {
  description = "Security group del cluster Aurora."
  value       = module.aurora.security_group_id
}

output "pgadmin_secret_arn" {
  description = "ARN del secreto con las credenciales de pgadmin."
  value       = module.secrets.secret_arn
}

output "audit_trail_arn" {
  description = "ARN del trail de auditoría."
  value       = module.audit.trail_arn
}

output "audit_bucket_name" {
  description = "Bucket con la evidencia de auditoría."
  value       = module.audit.bucket_id
}

output "audit_log_group_name" {
  description = "Log group de auditoría que ingiere la herramienta de observabilidad."
  value       = module.audit.log_group_name
}
