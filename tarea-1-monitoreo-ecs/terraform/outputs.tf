output "log_group_name" {
  description = "Log group con los eventos del monitor."
  value       = aws_cloudwatch_log_group.events.name
}

output "function_arn" {
  description = "ARN de la Lambda del monitor."
  value       = aws_lambda_function.monitor.arn
}

output "state_table_name" {
  description = "Tabla DynamoDB con el estado por servicio."
  value       = aws_dynamodb_table.state.name
}
