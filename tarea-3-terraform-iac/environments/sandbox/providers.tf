provider "aws" {
  region = local.aws_region

  # Evita aplicar un ambiente sobre la cuenta equivocada.
  allowed_account_ids = [local.aws_account_id]

  default_tags {
    tags = {
      Project     = "deuna"
      Environment = local.environment
      ManagedBy   = "terraform"
      Repository  = "github.com/deuna/data-platform"
      CostCenter  = "payments-platform"
      Owner       = "cloud-infrastructure"
    }
  }
}
