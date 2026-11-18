output "trail_arn" {
  description = "ARN del trail de auditoría."
  value       = aws_cloudtrail.this.arn
}

output "bucket_id" {
  description = "Bucket con la evidencia de auditoría."
  value       = module.bucket.bucket_id
}

output "kms_key_arn" {
  description = "Llave KMS de auditoría."
  value       = module.kms.key_arn
}

output "log_group_name" {
  description = "Log group que ingiere la herramienta de observabilidad."
  value       = aws_cloudwatch_log_group.this.name
}
