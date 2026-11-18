variable "bucket_name" {
  description = "Nombre global del bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "El nombre debe cumplir las reglas de nombres de bucket S3."
  }
}

variable "kms_key_arn" {
  description = "ARN de la llave KMS para el cifrado por defecto."
  type        = string
}

variable "access_log_bucket" {
  description = "Bucket destino de los server access logs. Null deshabilita el logging."
  type        = string
  default     = null
}

variable "lifecycle_rules" {
  description = "Parámetros del ciclo de vida de los objetos."
  type = object({
    transition_ia_days                 = optional(number, 30)
    transition_glacier_days            = optional(number, 90)
    expiration_days                    = optional(number) # null conserva la versión actual indefinidamente
    noncurrent_transition_days         = optional(number, 30)
    noncurrent_expiration_days         = optional(number, 365)
    noncurrent_versions_to_keep        = optional(number, 5)
    abort_incomplete_multipart_in_days = optional(number, 7)
  })
  default = {}
}

variable "object_lock_retention_days" {
  description = "Días de retención WORM en modo COMPLIANCE. Null deshabilita Object Lock."
  type        = number
  default     = null
}

variable "force_destroy" {
  description = "Permite destruir el bucket con objetos. Solo para ambientes efímeros."
  type        = bool
  default     = false
}

variable "data_classification" {
  description = "Clasificación de los datos almacenados."
  type        = string
  default     = "confidential"
}

variable "enforce_kms_headers" {
  description = "Rechaza cargas que pidan un cifrado distinto de SSE-KMS con la llave del bucket. Desactivar solo si un servicio AWS escribe con otras cabeceras."
  type        = bool
  default     = true
}

variable "additional_policy_json" {
  description = "Statements adicionales para la bucket policy, en JSON. Se combinan con las denegaciones del módulo."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
