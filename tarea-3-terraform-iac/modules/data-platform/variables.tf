# --- Contexto --------------------------------------------------------------

variable "environment" {
  description = "Ambiente de despliegue."
  type        = string

  validation {
    condition     = contains(["development", "sandbox", "production"], var.environment)
    error_message = "Valores permitidos: development, sandbox, production."
  }
}

variable "aws_region" {
  description = "Región AWS."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "Cuenta AWS del ambiente. El provider rechaza cualquier otra."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "La cuenta AWS debe tener 12 dígitos."
  }
}

variable "project" {
  description = "Nombre del proyecto. Prefijo de todos los recursos."
  type        = string
  default     = "deuna"
}

variable "data_classification" {
  description = "Clasificación de los datos del ambiente."
  type        = string
  default     = "confidential"
}

# --- Red existente ---------------------------------------------------------

variable "vpc_id" {
  description = "VPC existente del ambiente."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas existentes, en al menos dos zonas de disponibilidad."
  type        = list(string)
}

variable "app_security_group_ids" {
  description = "Security groups de los microservicios autorizados a conectarse a Aurora."
  type        = list(string)
  default     = []
}

variable "secretsmanager_endpoint_security_group_id" {
  description = "Security group del VPC endpoint de interfaz de Secrets Manager existente en la VPC."
  type        = string
}

# --- Acceso ----------------------------------------------------------------

variable "kms_admin_role_arns" {
  description = "Roles IAM que administran la llave KMS."
  type        = list(string)
  default     = []
}

variable "secret_reader_role_arns" {
  description = "Roles IAM de aplicación autorizados a leer el secreto de pgadmin."
  type        = list(string)
  default     = []
}

# --- KMS -------------------------------------------------------------------

variable "kms_deletion_window_in_days" {
  description = "Días de espera antes de eliminar la llave KMS."
  type        = number
  default     = 30
}

# --- S3 --------------------------------------------------------------------

variable "s3_access_log_bucket" {
  description = "Bucket central de access logs. Null deshabilita el logging."
  type        = string
  default     = null
}

variable "s3_object_lock_retention_days" {
  description = "Retención WORM del bucket. Null deshabilita Object Lock."
  type        = number
  default     = null
}

variable "s3_lifecycle_rules" {
  description = "Ciclo de vida del bucket. Ver el módulo s3 para los campos."
  type = object({
    transition_ia_days                 = optional(number, 30)
    transition_glacier_days            = optional(number, 90)
    expiration_days                    = optional(number)
    noncurrent_transition_days         = optional(number, 30)
    noncurrent_expiration_days         = optional(number, 365)
    noncurrent_versions_to_keep        = optional(number, 5)
    abort_incomplete_multipart_in_days = optional(number, 7)
  })
  default = {}
}

variable "s3_force_destroy" {
  description = "Permite destruir el bucket con objetos."
  type        = bool
  default     = false
}

# --- Aurora ----------------------------------------------------------------

variable "aurora_engine_version" {
  description = "Versión de Aurora PostgreSQL."
  type        = string
  default     = "16.6"
}

variable "aurora_instance_count" {
  description = "Número de instancias del cluster."
  type        = number
  default     = 2
}

variable "aurora_instance_class" {
  description = "Clase de instancia cuando el cluster es aprovisionado."
  type        = string
  default     = "db.r6g.large"
}

variable "aurora_serverless_scaling" {
  description = "Rango de ACU para Serverless v2. Null usa instancias aprovisionadas."
  type = object({
    min_capacity = number
    max_capacity = number
  })
  default = null
}

variable "aurora_backup_retention_days" {
  description = "Días de retención de backups automáticos."
  type        = number
  default     = 7
}

variable "aurora_deletion_protection" {
  description = "Protección contra eliminación del cluster."
  type        = bool
  default     = true
}

variable "aurora_skip_final_snapshot" {
  description = "Omite el snapshot final al destruir."
  type        = bool
  default     = false
}

variable "aurora_enhanced_monitoring_interval" {
  description = "Intervalo en segundos de Enhanced Monitoring."
  type        = number
  default     = 60
}

variable "aurora_performance_insights_retention_days" {
  description = "Retención de Performance Insights."
  type        = number
  default     = 7
}

variable "aurora_log_retention_days" {
  description = "Retención de los logs de PostgreSQL en CloudWatch."
  type        = number
  default     = 365
}

# --- Secrets Manager -------------------------------------------------------

variable "secret_rotation_days" {
  description = "Frecuencia de rotación de la contraseña de pgadmin."
  type        = number
  default     = 30
}

variable "secret_recovery_window_in_days" {
  description = "Días de recuperación tras eliminar el secreto."
  type        = number
  default     = 30
}

variable "master_password_version" {
  description = "Incrementar para regenerar y reenviar la contraseña inicial de pgadmin."
  type        = number
  default     = 1
}

# --- Auditoría -------------------------------------------------------------

variable "audit_reader_role_arns" {
  description = "Roles de auditoría o seguridad: los únicos que leen la evidencia de CloudTrail."
  type        = list(string)
  default     = []
}

variable "audit_log_s3_read_events" {
  description = "Audita también las lecturas de objetos del bucket de datos (eventos de datos con costo por evento)."
  type        = bool
  default     = true
}

variable "audit_retention_days" {
  description = "Días que se conserva la evidencia de auditoría en S3. Null la conserva indefinidamente."
  type        = number
  default     = 2555
}

variable "audit_object_lock_retention_days" {
  description = "Retención WORM de la evidencia. Null deshabilita Object Lock."
  type        = number
  default     = 365
}

variable "audit_log_retention_days" {
  description = "Retención de la copia de CloudTrail en CloudWatch Logs."
  type        = number
  default     = 365
}

# --- Observabilidad --------------------------------------------------------

variable "observability_log_destination_arn" {
  description = "Destino de la herramienta de observabilidad externa (Firehose, Kinesis o Lambda). Null si la herramienta ya suscribe los log groups por su cuenta."
  type        = string
  default     = null
}

variable "observability_log_destination_role_arn" {
  description = "Rol que CloudWatch Logs asume para escribir en el destino. Null si el destino es una Lambda."
  type        = string
  default     = null
}
