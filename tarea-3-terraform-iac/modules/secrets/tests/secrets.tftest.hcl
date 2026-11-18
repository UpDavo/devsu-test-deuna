# Pruebas del módulo Secrets Manager. Modo plan, sin cuenta AWS.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

# La consulta al Serverless Application Repository necesita la API real.
override_data {
  target = data.aws_serverlessapplicationrepository_application.rotation
  values = {
    application_id        = "arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser"
    semantic_version      = "1.1.0"
    required_capabilities = ["CAPABILITY_IAM", "CAPABILITY_RESOURCE_POLICY"]
  }
}

variables {
  name                   = "deuna-test/aurora/pgadmin"
  kms_key_arn            = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  password               = "test-only" # gitleaks:allow (valor ficticio de prueba)
  db_host                = "deuna-test-aurora.cluster-xxxx.us-east-1.rds.amazonaws.com"
  db_name                = "deuna"
  db_cluster_identifier  = "deuna-test-aurora"
  db_security_group_id   = "sg-00000000000000000"
  vpc_id                 = "vpc-00000000000000000"
  private_subnet_ids     = ["subnet-0000000000000000a", "subnet-0000000000000000b"]
  allowed_principal_arns = ["arn:aws:iam::111111111111:role/dba-break-glass"]

  secretsmanager_endpoint_security_group_id = "sg-0000000000000vpce"
}

run "secret_is_encrypted_and_rotated" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.this.kms_key_id == var.kms_key_arn
    error_message = "El secreto debe cifrarse con la llave KMS indicada."
  }

  assert {
    condition     = aws_secretsmanager_secret_rotation.this.rotation_rules[0].automatically_after_days == 30
    error_message = "La rotación automática debe estar configurada a 30 días."
  }

  assert {
    condition     = aws_secretsmanager_secret_policy.this.block_public_policy == true
    error_message = "La resource policy debe bloquear políticas públicas."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string == null
    error_message = "El valor del secreto no debe quedar en el estado: solo se admite el atributo write-only."
  }
}

run "rotation_lambda_is_isolated" {
  command = plan

  assert {
    condition     = aws_serverlessapplicationrepository_cloudformation_stack.rotation.name == "deuna-test-aurora-pgadmin-rotation"
    error_message = "El nombre de la Lambda de rotación debe derivarse del secreto."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_rotation.from_port == 5432 && aws_vpc_security_group_ingress_rule.db_from_rotation.cidr_ipv4 == null
    error_message = "La Lambda solo debe alcanzar el puerto de PostgreSQL, por security group."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.rotation_to_api.cidr_ipv4 == null && aws_vpc_security_group_egress_rule.rotation_to_api.referenced_security_group_id == var.secretsmanager_endpoint_security_group_id
    error_message = "La Lambda no debe tener salida a internet: solo al VPC endpoint de Secrets Manager."
  }
}
