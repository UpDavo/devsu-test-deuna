output "cluster_arn" {
  description = "ARN del cluster."
  value       = aws_rds_cluster.this.arn
}

output "cluster_identifier" {
  description = "Identificador del cluster."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "endpoint" {
  description = "Endpoint de escritura."
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Endpoint de lectura."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "Puerto de escucha."
  value       = aws_rds_cluster.this.port
}

output "database_name" {
  description = "Base de datos inicial."
  value       = aws_rds_cluster.this.database_name
}

output "master_username" {
  description = "Usuario administrador."
  value       = aws_rds_cluster.this.master_username
}

output "security_group_id" {
  description = "Security group del cluster."
  value       = aws_security_group.this.id
}
