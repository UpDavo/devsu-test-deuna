# Pruebas del módulo S3. Modo plan, sin cuenta AWS.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

variables {
  bucket_name = "deuna-test-data"
  kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000"
}

run "bucket_is_private_versioned_and_encrypted" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "Los cuatro bloqueos de acceso público deben estar activos."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "El versionado debe estar habilitado."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.this.rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" &&
      r.apply_server_side_encryption_by_default[0].kms_master_key_id == var.kms_key_arn &&
      r.bucket_key_enabled
    ])
    error_message = "El cifrado por defecto debe usar la llave KMS indicada, con Bucket Key."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule) >= 1
    error_message = "Debe existir una lifecycle policy."
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy debe ser false por defecto."
  }
}

run "bucket_policy_denies_insecure_access" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.this.json).Statement : s.Effect == "Deny"
    ])
    error_message = "La bucket policy solo debe contener denegaciones: no abre acceso a nadie."
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.this.json).Statement : s
      if s.Sid == "DenyInsecureTransport" && s.Condition.Bool["aws:SecureTransport"] == "false"
    ]) == 1
    error_message = "Debe denegar las peticiones sin TLS."
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.this.json).Statement : s
      if s.Sid == "DenyWrongKmsKey"
    ]) == 1
    error_message = "Debe denegar cargas cifradas con otra llave."
  }
}

run "object_lock_is_opt_in" {
  command = plan

  variables {
    object_lock_retention_days = 2555
  }

  assert {
    condition     = aws_s3_bucket.this.object_lock_enabled == true
    error_message = "Object Lock debe activarse cuando se define retención."
  }

  assert {
    condition     = aws_s3_bucket_object_lock_configuration.this[0].rule[0].default_retention[0].mode == "COMPLIANCE"
    error_message = "La retención debe ser COMPLIANCE."
  }
}
