variable "name" {
  description = "Prefijo de los recursos del monitor."
  type        = string
  default     = "ecs-capacity-monitor"
}

variable "environment" {
  description = "Ambiente. Va en cada evento y en la clave de deduplicación."
  type        = string
}

variable "kms_key_arn" {
  description = "Llave KMS para el log group y la tabla de estado. Su policy debe permitir logs y dynamodb."
  type        = string
}

variable "schedule_expression" {
  description = "Frecuencia de evaluación."
  type        = string
  default     = "rate(1 minute)"
}

variable "warning_ratio" {
  description = "Fracción del máximo a partir de la cual se emite el aviso temprano."
  type        = number
  default     = 0.8

  validation {
    condition     = var.warning_ratio > 0 && var.warning_ratio < 1
    error_message = "Debe estar entre 0 y 1."
  }
}

variable "sustain_seconds" {
  description = "Tiempo continuo en el máximo antes de la alerta accionable."
  type        = number
  default     = 300
}

variable "recovery_seconds" {
  description = "Tiempo continuo por debajo del máximo antes de resolver la alerta."
  type        = number
  default     = 600
}

variable "renotify_seconds" {
  description = "Intervalo de recordatorio mientras la saturación continúa."
  type        = number
  default     = 1800
}

variable "snapshot_interval_seconds" {
  description = "Cada cuánto se emite el snapshot de los servicios sanos. Los servicios con problemas emiten cada minuto."
  type        = number
  default     = 300
}

variable "cluster_saturation_threshold" {
  description = "Servicios en el máximo a partir de los cuales el cluster se considera saturado."
  type        = number
  default     = 3
}

variable "dashboard_url" {
  description = "URL del dashboard de guardia, incluida en cada alerta."
  type        = string
  default     = ""
}

variable "runbook_url" {
  description = "URL del runbook, incluida en cada alerta."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Retención en CloudWatch. La historia larga vive en la herramienta externa."
  type        = number
  default     = 30
}

variable "log_destination_arn" {
  description = "Destino de la suscripción hacia la herramienta externa (Firehose o Lambda forwarder). Null si la herramienta ya suscribe los log groups por su cuenta."
  type        = string
  default     = null
}

variable "log_destination_role_arn" {
  description = "Rol que CloudWatch Logs asume para escribir en el destino. Requerido para Firehose."
  type        = string
  default     = null
}

variable "alarm_topic_arn" {
  description = "Tópico SNS para las alarmas de respaldo. Null deshabilita las alarmas."
  type        = string
  default     = null
}

variable "fallback_alarm_clusters" {
  description = "Clusters con alarma de respaldo en CloudWatch, por si la herramienta externa falla."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
