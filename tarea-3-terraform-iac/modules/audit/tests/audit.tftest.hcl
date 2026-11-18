# Pruebas del módulo de auditoría. Modo plan, sin cuenta AWS.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = module.kms.data.aws_caller_identity.current
  values = {
    account_id = "111111111111"
  }
}

variables {
  name                  = "deuna-test"
  account_id            = "111111111111"
  region                = "us-east-1"
  bucket_name           = "deuna-test-audit-111111111111-us-east-1"
  data_bucket_arns      = ["arn:aws:s3:::deuna-test-data"]
  reader_principal_arns = ["arn:aws:iam::111111111111:role/security-auditor"]
}

run "trail_is_tamper_evident_and_covers_data_bucket" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudtrail.this.enable_log_file_validation,
      aws_cloudtrail.this.is_multi_region_trail,
      aws_cloudtrail.this.include_global_service_events,
    ])
    error_message = "El trail debe validar la integridad de los logs y cubrir todas las regiones."
  }

  assert {
    condition = contains(
      flatten([
        for s in aws_cloudtrail.this.advanced_event_selector : [
          for f in s.field_selector : tolist(f.starts_with) if f.field == "resources.ARN"
        ]
      ]),
      "arn:aws:s3:::deuna-test-data/"
    )
    error_message = "Los eventos de datos deben cubrir los objetos del bucket de datos."
  }

  assert {
    condition     = length(aws_cloudwatch_log_subscription_filter.sensitive) == 0
    error_message = "Sin destino no debe crearse el subscription filter."
  }
}

run "only_this_trail_can_use_key_and_bucket" {
  command = plan

  assert {
    condition = alltrue([
      for s in concat(
        jsondecode(data.aws_iam_policy_document.key_cloudtrail.json).Statement,
        jsondecode(data.aws_iam_policy_document.bucket_cloudtrail.json).Statement,
      ) :
      s.Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:us-east-1:111111111111:trail/deuna-test-audit"
      if try(s.Principal.Service, "") == "cloudtrail.amazonaws.com"
    ])
    error_message = "Cada permiso de CloudTrail debe limitarse a este trail con aws:SourceArn."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.key_cloudtrail.json).Statement :
      !contains(flatten([s.Action]), "kms:*")
    ])
    error_message = "Ningún statement de la llave de auditoría puede otorgar kms:*."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(data.aws_iam_policy_document.bucket_cloudtrail.json).Statement :
      s.Sid == "DenyReadOutsideAuditors" && s.Effect == "Deny"
    ])
    error_message = "La evidencia solo debe poder leerla el rol de auditoría."
  }
}

run "forwards_sensitive_events_when_destination_is_set" {
  command = plan

  variables {
    log_destination_arn      = "arn:aws:firehose:us-east-1:111111111111:deliverystream/observability"
    log_destination_role_arn = "arn:aws:iam::111111111111:role/cwlogs-to-firehose"
  }

  assert {
    condition = alltrue([
      strcontains(aws_cloudwatch_log_subscription_filter.sensitive[0].filter_pattern, "GetSecretValue"),
      strcontains(aws_cloudwatch_log_subscription_filter.sensitive[0].filter_pattern, "StopLogging"),
    ])
    error_message = "El filtro debe enviar la lectura del secreto y los intentos de apagar la auditoría."
  }
}

run "rejects_empty_data_buckets" {
  command = plan

  variables {
    data_bucket_arns = []
  }

  expect_failures = [var.data_bucket_arns]
}
