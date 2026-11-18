output "secret_arn" {
  description = "ARN del secreto."
  value       = aws_secretsmanager_secret.this.arn
}

output "secret_name" {
  description = "Nombre del secreto."
  value       = aws_secretsmanager_secret.this.name
}

output "rotation_lambda_arn" {
  description = "ARN de la Lambda de rotación."
  value       = aws_secretsmanager_secret_rotation.this.rotation_lambda_arn
}
