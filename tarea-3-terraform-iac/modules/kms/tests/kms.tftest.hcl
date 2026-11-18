# Pruebas del módulo KMS. Corren en modo plan, sin cuenta AWS:
# la key policy se calcula de verdad y se verifica su contenido.

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
  alias                = "deuna-test-data"
  description          = "Llave de prueba"
  admin_principal_arns = ["arn:aws:iam::111111111111:role/security-kms-admin"]
}

run "symmetric_key_with_rotation" {
  command = plan

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true
    error_message = "La rotación automática debe estar habilitada."
  }

  assert {
    condition     = aws_kms_key.this.customer_master_key_spec == "SYMMETRIC_DEFAULT" && aws_kms_key.this.key_usage == "ENCRYPT_DECRYPT"
    error_message = "La llave debe ser simétrica y de cifrado."
  }

  assert {
    condition     = aws_kms_key.this.tags["DataClassification"] == "confidential"
    error_message = "La llave debe llevar el tag de clasificación."
  }
}

run "key_policy_is_least_privilege" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.this.json).Statement :
      !contains(flatten([s.Action]), "kms:*")
    ])
    error_message = "Ningún statement puede otorgar kms:*."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.this.json).Statement :
      !contains(flatten([s.Action]), "kms:Decrypt")
      if contains(["AccountBreakGlassAdministration", "KeyAdministrators"], s.Sid)
    ])
    error_message = "Los administradores de la llave no deben poder descifrar."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.this.json).Statement :
      s.Condition.StringEquals["kms:CallerAccount"] == "111111111111"
      if s.Sid == "UseThroughAllowedServices"
    ])
    error_message = "El uso vía servicio debe limitarse a la cuenta propia."
  }
}

run "rejects_alias_with_prefix" {
  command = plan

  variables {
    alias = "alias/deuna-test"
  }

  expect_failures = [var.alias]
}
