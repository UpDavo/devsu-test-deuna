output "key_arn" {
  description = "ARN de la llave KMS."
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "ID de la llave KMS."
  value       = aws_kms_key.this.key_id
}

output "alias_name" {
  description = "Alias de la llave KMS."
  value       = aws_kms_alias.this.name
}
