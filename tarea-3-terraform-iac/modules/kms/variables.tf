variable "alias" {
  description = "Alias de la llave, sin el prefijo alias/."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]+$", var.alias)) && !startswith(var.alias, "alias/")
    error_message = "El alias solo admite letras, números, /, _ y -, y no debe incluir el prefijo alias/."
  }
}

variable "description" {
  description = "Descripción de la llave."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Días de espera antes de eliminar la llave."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "El valor debe estar entre 7 y 30 días."
  }
}

variable "rotation_period_in_days" {
  description = "Período de rotación automática del material de la llave."
  type        = number
  default     = 365

  validation {
    condition     = var.rotation_period_in_days >= 90 && var.rotation_period_in_days <= 2560
    error_message = "El valor debe estar entre 90 y 2560 días."
  }
}

variable "admin_principal_arns" {
  description = "Roles IAM que administran la llave. No reciben permisos criptográficos."
  type        = list(string)
  default     = []
}

variable "allowed_via_services" {
  description = "Servicios AWS que pueden usar la llave a nombre de principals de la cuenta (prefijo del servicio, por ejemplo s3, rds, secretsmanager)."
  type        = list(string)
  default     = ["s3", "rds", "secretsmanager"]
}

variable "direct_user_principal_arns" {
  description = "Roles IAM que pueden cifrar y descifrar directamente con la llave, fuera de un servicio AWS."
  type        = list(string)
  default     = []
}

variable "allow_cloudwatch_logs" {
  description = "Permite a CloudWatch Logs cifrar log groups de la cuenta con esta llave."
  type        = bool
  default     = true
}

variable "additional_policy_json" {
  description = "Statements adicionales para la key policy, en JSON. Ninguno debe otorgar kms:*."
  type        = string
  default     = null
}

variable "data_classification" {
  description = "Clasificación de los datos que protege la llave."
  type        = string
  default     = "confidential"

  validation {
    condition     = contains(["public", "internal", "confidential", "restricted"], var.data_classification)
    error_message = "Valores permitidos: public, internal, confidential, restricted."
  }
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
