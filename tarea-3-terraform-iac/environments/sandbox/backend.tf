# Estado remoto del ambiente sandbox: bucket S3 en la cuenta del ambiente
# (marcador), con locking nativo (use_lockfile, Terraform >= 1.10). Las
# credenciales son las del rol OIDC del job: no hay secretos aquí.
terraform {
  backend "s3" {
    bucket       = "deuna-tfstate-222222222222-us-east-1"
    key          = "data-platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
