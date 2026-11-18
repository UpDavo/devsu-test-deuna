# Pruebas de la composición: el plan completo resuelve y las
# validaciones de entrada rechazan valores peligrosos. Sin cuenta AWS.

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
    arn        = "arn:aws:sts::111111111111:assumed-role/github-terraform-apply/pipeline"
  }
}

override_data {
  target = data.aws_iam_session_context.current
  values = {
    issuer_arn = "arn:aws:iam::111111111111:role/github-terraform-apply"
  }
}

override_data {
  target = module.kms.data.aws_caller_identity.current
  values = {
    account_id = "111111111111"
  }
}

override_data {
  target = module.audit.module.kms.data.aws_caller_identity.current
  values = {
    account_id = "111111111111"
  }
}

override_data {
  target = module.secrets.data.aws_serverlessapplicationrepository_application.rotation
  values = {
    application_id        = "arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser"
    semantic_version      = "1.1.0"
    required_capabilities = ["CAPABILITY_IAM", "CAPABILITY_RESOURCE_POLICY"]
  }
}

variables {
  environment            = "development"
  aws_account_id         = "111111111111"
  vpc_id                 = "vpc-00000000000000000"
  private_subnet_ids     = ["subnet-0000000000000000a", "subnet-0000000000000000b"]
  app_security_group_ids = ["sg-00000000000000000"]

  secretsmanager_endpoint_security_group_id = "sg-0000000000000vpce"
}

run "full_stack_plans" {
  command = plan

  assert {
    condition     = local.bucket_name == "deuna-development-data-111111111111-us-east-1"
    error_message = "El nombre del bucket debe incluir ambiente, cuenta y región."
  }

  assert {
    condition     = contains(local.secret_allowed_arns, "arn:aws:iam::111111111111:role/github-terraform-apply")
    error_message = "El rol del pipeline debe poder leer la versión del secreto para el refresh."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "rejects_malformed_account_id" {
  command = plan

  variables {
    aws_account_id = "1234"
  }

  expect_failures = [var.aws_account_id]
}
