variable "name" {
  description = "Identificador del cluster."
  type        = string
}

variable "vpc_id" {
  description = "VPC donde se despliega el cluster."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas, en al menos dos zonas de disponibilidad."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Aurora requiere subnets en al menos dos zonas de disponibilidad."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups de las aplicaciones autorizadas a conectarse al puerto de la base."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "ARN de la llave KMS para almacenamiento, Performance Insights y logs."
  type        = string
}

variable "engine_version" {
  description = "Versión de Aurora PostgreSQL."
  type        = string
  default     = "16.6"
}

variable "parameter_group_family" {
  description = "Familia del parameter group. Debe coincidir con la versión mayor del motor."
  type        = string
  default     = "aurora-postgresql16"
}

variable "database_name" {
  description = "Base de datos inicial."
  type        = string
  default     = "deuna"
}

variable "port" {
  description = "Puerto de escucha."
  type        = number
  default     = 5432
}

variable "master_username" {
  description = "Usuario administrador."
  type        = string
  default     = "pgadmin"
}

variable "master_password" {
  description = "Contraseña inicial del administrador. Efímera: no se guarda en el plan ni en el estado."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "master_password_version" {
  description = "Incrementar para forzar el reenvío de la contraseña inicial. La rotación normal la hace Secrets Manager."
  type        = number
  default     = 1
}

variable "instance_count" {
  description = "Número de instancias. Dos o más habilitan failover entre zonas."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "Se requiere al menos una instancia."
  }
}

variable "instance_class" {
  description = "Clase de instancia. Usar db.serverless junto con serverless_scaling para Serverless v2."
  type        = string
  default     = "db.r6g.large"
}

variable "serverless_scaling" {
  description = "Rango de ACU para Serverless v2. Null usa instancias aprovisionadas."
  type = object({
    min_capacity = number
    max_capacity = number
  })
  default = null
}

variable "backup_retention_days" {
  description = "Días de retención de los backups automáticos."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "El valor debe estar entre 1 y 35 días."
  }
}

variable "preferred_backup_window" {
  description = "Ventana diaria de backup en UTC."
  type        = string
  default     = "07:00-08:00"
}

variable "preferred_maintenance_window" {
  description = "Ventana semanal de mantenimiento en UTC."
  type        = string
  default     = "sun:08:30-sun:09:30"
}

variable "deletion_protection" {
  description = "Protección contra eliminación del cluster."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Omite el snapshot final al destruir. Solo para ambientes efímeros."
  type        = bool
  default     = false
}

variable "enhanced_monitoring_interval" {
  description = "Intervalo en segundos de Enhanced Monitoring. Cero lo deshabilita."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.enhanced_monitoring_interval)
    error_message = "Valores permitidos: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "performance_insights_retention_days" {
  description = "Retención de Performance Insights. Siete días no tiene costo adicional."
  type        = number
  default     = 7
}

variable "log_retention_days" {
  description = "Retención del log group de PostgreSQL en CloudWatch."
  type        = number
  default     = 365
}

variable "slow_query_threshold_ms" {
  description = "Umbral en milisegundos para registrar consultas lentas."
  type        = number
  default     = 1000
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
