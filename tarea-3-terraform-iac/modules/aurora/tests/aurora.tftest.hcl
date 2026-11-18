# Pruebas del módulo Aurora. Modo plan, sin cuenta AWS.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

variables {
  name                       = "deuna-test-aurora"
  vpc_id                     = "vpc-00000000000000000"
  private_subnet_ids         = ["subnet-0000000000000000a", "subnet-0000000000000000b"]
  allowed_security_group_ids = ["sg-00000000000000000"]
  kms_key_arn                = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  master_password            = "test-only" # gitleaks:allow (valor ficticio de prueba)
}

run "cluster_is_encrypted_private_and_backed_up" {
  command = plan

  assert {
    condition     = aws_rds_cluster.this.storage_encrypted == true && aws_rds_cluster.this.kms_key_id == var.kms_key_arn
    error_message = "El cluster debe cifrarse con la llave KMS indicada."
  }

  assert {
    condition     = aws_rds_cluster.this.backup_retention_period >= 1
    error_message = "Los backups automáticos deben estar habilitados."
  }

  assert {
    condition     = aws_rds_cluster.this.deletion_protection == true
    error_message = "La protección contra eliminación debe estar activa por defecto."
  }

  assert {
    condition     = aws_rds_cluster.this.iam_database_authentication_enabled == true
    error_message = "La autenticación IAM debe estar habilitada."
  }

  assert {
    condition     = contains(aws_rds_cluster.this.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "Los logs de PostgreSQL deben exportarse a CloudWatch."
  }

  assert {
    condition     = alltrue([for i in aws_rds_cluster_instance.this : i.publicly_accessible == false])
    error_message = "Ninguna instancia puede ser pública."
  }

  assert {
    condition = alltrue([
      for i in aws_rds_cluster_instance.this :
      i.performance_insights_enabled && i.performance_insights_kms_key_id == var.kms_key_arn && i.monitoring_interval > 0
    ])
    error_message = "Performance Insights y Enhanced Monitoring deben estar habilitados."
  }

  assert {
    condition     = aws_cloudwatch_log_group.postgresql.kms_key_id == var.kms_key_arn
    error_message = "El log group debe cifrarse con la llave KMS."
  }
}

run "access_only_from_declared_security_groups" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.apps) == 1
    error_message = "Debe existir una regla de ingreso por cada security group autorizado."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.apps :
      r.cidr_ipv4 == null && r.cidr_ipv6 == null && r.from_port == 5432 && r.to_port == 5432
    ])
    error_message = "El ingreso debe ser por security group y solo al puerto de PostgreSQL."
  }

  assert {
    condition = anytrue([
      for p in aws_rds_cluster_parameter_group.this.parameter : p.name == "rds.force_ssl" && p.value == "1"
    ])
    error_message = "El cluster debe forzar TLS."
  }
}

run "serverless_v2_for_low_cost_environments" {
  command = plan

  variables {
    instance_count     = 1
    serverless_scaling = { min_capacity = 0.5, max_capacity = 2 }
  }

  assert {
    condition     = aws_rds_cluster_instance.this[0].instance_class == "db.serverless"
    error_message = "Con serverless_scaling la instancia debe ser db.serverless."
  }
}

run "rejects_single_subnet" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-0000000000000000a"]
  }

  expect_failures = [var.private_subnet_ids]
}
