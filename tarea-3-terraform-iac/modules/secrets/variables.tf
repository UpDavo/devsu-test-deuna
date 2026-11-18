variable "name" {
  description = "Nombre del secreto."
  type        = string
}

variable "description" {
  description = "Descripción del secreto."
  type        = string
  default     = "Credenciales del usuario administrador de Aurora PostgreSQL"
}

variable "kms_key_arn" {
  description = "ARN de la llave KMS que cifra el secreto."
  type        = string
}

variable "username" {
  description = "Usuario de base de datos."
  type        = string
  default     = "pgadmin"
}

variable "password" {
  description = "Contraseña inicial. Efímera: no se guarda en el plan ni en el estado."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "password_version" {
  description = "Incrementar para forzar la reescritura del valor inicial."
  type        = number
  default     = 1
}

variable "db_host" {
  description = "Endpoint de escritura del cluster."
  type        = string
}

variable "db_port" {
  description = "Puerto del cluster."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Base de datos por defecto."
  type        = string
}

variable "db_cluster_identifier" {
  description = "Identificador del cluster."
  type        = string
}

variable "db_security_group_id" {
  description = "Security group del cluster. Se le agrega el ingreso desde la Lambda de rotación."
  type        = string
}

variable "vpc_id" {
  description = "VPC de la Lambda de rotación."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas de la Lambda de rotación."
  type        = list(string)
}

variable "secretsmanager_endpoint_security_group_id" {
  description = "Security group del VPC endpoint de interfaz de Secrets Manager. Único destino HTTPS de la Lambda."
  type        = string
}

variable "rotation_days" {
  description = "Frecuencia de rotación automática."
  type        = number
  default     = 30

  validation {
    condition     = var.rotation_days >= 1 && var.rotation_days <= 365
    error_message = "El valor debe estar entre 1 y 365 días."
  }
}

variable "rotation_app_semantic_version" {
  description = "Versión de la aplicación SAR de rotación. Null usa la más reciente."
  type        = string
  default     = null
}

variable "allowed_principal_arns" {
  description = "Roles IAM autorizados a leer o modificar el valor del secreto. La Lambda de rotación se agrega sola."
  type        = list(string)
}

variable "recovery_window_in_days" {
  description = "Días de recuperación tras eliminar el secreto."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
