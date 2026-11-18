data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  alarms_enabled = var.alarm_topic_arn != null
}

# --- Log group: punto de integración con la herramienta externa ----------------

resource "aws_cloudwatch_log_group" "events" {
  # checkov:skip=CKV_AWS_338:Eventos operativos; la historia larga se conserva en la herramienta externa
  name              = "/deuna/observability/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

# Solo los eventos del monitor llegan a la herramienta externa. Las líneas
# START/END/REPORT del runtime quedan en CloudWatch.
resource "aws_cloudwatch_log_subscription_filter" "external" {
  count = var.log_destination_arn != null ? 1 : 0

  name            = "${var.name}-to-observability"
  log_group_name  = aws_cloudwatch_log_group.events.name
  filter_pattern  = "{ $.event_type = \"ecs.capacity.*\" }"
  destination_arn = var.log_destination_arn
  role_arn        = var.log_destination_role_arn
}

# --- Estado ----------------------------------------------------------------

resource "aws_dynamodb_table" "state" {
  name         = "${var.name}-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}

# --- Lambda ----------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/capacity_monitor.py"
  output_path = "${path.module}/.build/capacity_monitor.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = var.tags
}

# Solo lectura sobre ECS, Auto Scaling y CloudWatch. Escritura solo en su
# tabla y su log group.
data "aws_iam_policy_document" "lambda" {
  statement {
    sid = "ReadScalingConfiguration"
    # Estas acciones no admiten permisos a nivel de recurso.
    actions = [
      "application-autoscaling:DescribeScalableTargets",
      "application-autoscaling:DescribeScalingActivities",
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"] # checkov:skip=CKV_AWS_356:Las acciones Describe y GetMetricData no admiten recursos específicos
  }

  statement {
    sid       = "ReadServices"
    actions   = ["ecs:DescribeServices", "ecs:ListTagsForResource"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/*/*"]
  }

  statement {
    sid       = "State"
    actions   = ["dynamodb:Scan", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"]
    resources = [aws_dynamodb_table.state.arn]
  }

  statement {
    sid       = "StateEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "WriteEvents"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.events.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # checkov:skip=CKV_AWS_356:X-Ray no admite recursos específicos
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "capacity-monitor"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_lambda_function" "monitor" {
  # checkov:skip=CKV_AWS_116:Invocación programada e idempotente; la siguiente ejecución, un minuto después, reemplaza al reintento
  # checkov:skip=CKV_AWS_117:Solo llama APIs de AWS; dentro de una VPC requeriría NAT o cuatro VPC endpoints sin ganancia de seguridad
  # checkov:skip=CKV_AWS_173:Las variables de entorno no contienen secretos
  # checkov:skip=CKV_AWS_272:Código interno desplegado solo por el pipeline; la firma se suma al adoptar AWS Signer en la organización
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "capacity_monitor.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = 256
  timeout          = 50

  # Una sola ejecución a la vez: dos ejecuciones simultáneas competirían por
  # el estado y podrían duplicar alertas.
  reserved_concurrent_executions = 1

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.events.name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ENVIRONMENT                  = var.environment
      STATE_TABLE                  = aws_dynamodb_table.state.name
      WARNING_RATIO                = tostring(var.warning_ratio)
      SUSTAIN_SECONDS              = tostring(var.sustain_seconds)
      RECOVERY_SECONDS             = tostring(var.recovery_seconds)
      RENOTIFY_SECONDS             = tostring(var.renotify_seconds)
      SNAPSHOT_INTERVAL_SECONDS    = tostring(var.snapshot_interval_seconds)
      CLUSTER_SATURATION_THRESHOLD = tostring(var.cluster_saturation_threshold)
      DASHBOARD_URL                = var.dashboard_url
      RUNBOOK_URL                  = var.runbook_url
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.lambda]
}

# --- Programación ----------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.monitor.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-monitor"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "monitor" {
  # checkov:skip=CKV_AWS_297:El schedule no lleva payload; no hay datos que cifrar
  name                = var.name
  schedule_expression = var.schedule_expression

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.monitor.arn
    role_arn = aws_iam_role.scheduler.arn

    # Sin reintentos: un reintento tardío se solaparía con la ejecución siguiente.
    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 60
    }
  }
}

# --- Alarmas de respaldo (CloudWatch -> SNS) -------------------------------
# Cubren el caso en que la herramienta externa o el propio monitor fallan.

# El monitor dejó de correr o falla: sin él no hay detección.
resource "aws_cloudwatch_metric_alarm" "monitor_errors" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name          = "${var.name}-errors"
  alarm_description   = "El monitor de capacidad ECS falla. La detección de servicios en el máximo está detenida."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.monitor.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "monitor_not_running" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name          = "${var.name}-not-running"
  alarm_description   = "El monitor de capacidad ECS no se ejecutó en 5 minutos."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.monitor.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  tags = var.tags
}

# Respaldo de la alerta principal, desde la métrica EMF del resumen por cluster.
resource "aws_cloudwatch_metric_alarm" "services_at_max" {
  for_each = local.alarms_enabled ? toset(var.fallback_alarm_clusters) : toset([])

  alarm_name          = "${var.name}-${each.value}-services-at-max"
  alarm_description   = "Hay servicios del cluster ${each.value} en su máximo de tareas hace 10 minutos. Respaldo de la alerta de la herramienta externa."
  namespace           = "Deuna/ECSCapacity"
  metric_name         = "ServicesAtMax"
  dimensions          = { Cluster = each.value }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  tags = var.tags
}
