variable "name" {
  description = "Prefijo de los recursos, por ejemplo deuna-production."
  type        = string
}

variable "account_id" {
  description = "Cuenta AWS del ambiente."
  type        = string
}

variable "region" {
  description = "Región del trail."
  type        = string
}

variable "bucket_name" {
  description = "Nombre global del bucket de evidencia."
  type        = string
}

variable "data_bucket_arns" {
  description = "Buckets cuyos objetos se auditan con eventos de datos."
  type        = list(string)

  validation {
    condition     = length(var.data_bucket_arns) > 0
    error_message = "Debe haber al menos un bucket auditado."
  }
}

variable "log_s3_read_events" {
  description = "Registra también las lecturas de objetos. En false solo se registran escrituras y borrados (menor costo)."
  type        = bool
  default     = true
}

variable "admin_principal_arns" {
  description = "Roles que administran la llave de auditoría. No pueden descifrar."
  type        = list(string)
  default     = []
}

variable "reader_principal_arns" {
  description = "Roles de auditoría: los únicos que leen y descifran la evidencia."
  type        = list(string)
  default     = []
}

variable "kms_deletion_window_in_days" {
  description = "Días de espera antes de eliminar la llave de auditoría."
  type        = number
  default     = 30
}

variable "retention_days" {
  description = "Días que se conserva la evidencia en S3. Null la conserva indefinidamente."
  type        = number
  default     = 2555
}

variable "object_lock_retention_days" {
  description = "Retención WORM en modo COMPLIANCE. Null deshabilita Object Lock."
  type        = number
  default     = 365
}

variable "log_retention_days" {
  description = "Retención de la copia en CloudWatch Logs. La evidencia de largo plazo vive en S3."
  type        = number
  default     = 365
}

variable "force_destroy" {
  description = "Permite destruir el bucket con objetos. Solo para ambientes efímeros."
  type        = bool
  default     = false
}

variable "log_destination_arn" {
  description = "Destino de la herramienta de observabilidad (Firehose, Kinesis o Lambda). Null no crea el subscription filter."
  type        = string
  default     = null
}

variable "log_destination_role_arn" {
  description = "Rol que CloudWatch Logs asume para escribir en el destino. Null si el destino es una Lambda."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
