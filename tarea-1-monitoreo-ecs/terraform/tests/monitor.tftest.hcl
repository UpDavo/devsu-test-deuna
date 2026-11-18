# Pruebas del módulo del monitor. Corren en modo plan, sin cuenta AWS:
# credenciales ficticias y overrides para los valores que solo AWS conoce.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111111111111"
  }
}

variables {
  environment = "test"
  kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000"
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_lambda_function.monitor.reserved_concurrent_executions == 1
    error_message = "La Lambda debe tener una sola ejecución a la vez."
  }

  assert {
    condition     = aws_lambda_function.monitor.runtime == "python3.13" && aws_lambda_function.monitor.timeout < 60
    error_message = "Runtime python3.13 y timeout menor a la frecuencia de un minuto."
  }

  assert {
    condition     = aws_lambda_function.monitor.environment[0].variables["ENVIRONMENT"] == "test"
    error_message = "El ambiente debe llegar a la Lambda."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.target[0].retry_policy[0].maximum_retry_attempts == 0
    error_message = "El schedule no debe reintentar."
  }

  assert {
    condition     = length(aws_cloudwatch_log_subscription_filter.external) == 0
    error_message = "Sin destino no debe haber suscripción."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.monitor_errors) == 0 && length(aws_cloudwatch_metric_alarm.services_at_max) == 0
    error_message = "Sin tópico SNS no debe haber alarmas."
  }
}

run "encryption_and_recovery" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.events.kms_key_id == var.kms_key_arn
    error_message = "El log group debe cifrarse con la llave del ambiente."
  }

  assert {
    condition     = aws_dynamodb_table.state.server_side_encryption[0].kms_key_arn == var.kms_key_arn
    error_message = "La tabla de estado debe cifrarse con la llave del ambiente."
  }

  assert {
    condition     = aws_dynamodb_table.state.point_in_time_recovery[0].enabled
    error_message = "La tabla de estado debe tener PITR."
  }
}

# La policy de permisos depende de ARN que solo existen tras el apply; las
# trust policies sí se resuelven en plan y fijan quién puede asumir cada rol.
run "roles_trust_only_their_service_in_this_account" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.lambda_assume.json).Statement :
      s.Principal.Service == "lambda.amazonaws.com" && s.Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    ])
    error_message = "El rol de la Lambda solo puede asumirlo Lambda desde la misma cuenta."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.scheduler_assume.json).Statement :
      s.Principal.Service == "scheduler.amazonaws.com" && s.Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    ])
    error_message = "El rol del scheduler solo puede asumirlo Scheduler desde la misma cuenta."
  }
}

run "alarms_and_subscription_enabled" {
  command = plan

  variables {
    alarm_topic_arn          = "arn:aws:sns:us-east-1:111111111111:oncall"
    fallback_alarm_clusters  = ["payments", "core"]
    log_destination_arn      = "arn:aws:firehose:us-east-1:111111111111:deliverystream/observability"
    log_destination_role_arn = "arn:aws:iam::111111111111:role/logs-to-firehose"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.monitor_errors) == 1 && length(aws_cloudwatch_metric_alarm.monitor_not_running) == 1
    error_message = "Con tópico SNS deben existir las alarmas del monitor."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.services_at_max) == 2
    error_message = "Debe haber una alarma de respaldo por cluster."
  }

  assert {
    condition     = aws_cloudwatch_log_subscription_filter.external[0].filter_pattern == "{ $.event_type = \"ecs.capacity.*\" }"
    error_message = "Solo los eventos del monitor deben ir a la herramienta externa."
  }
}

run "warning_ratio_out_of_range" {
  command = plan

  variables {
    warning_ratio = 1.2
  }

  expect_failures = [var.warning_ratio]
}
