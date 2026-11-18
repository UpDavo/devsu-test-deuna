# Caso práctico — Ingeniero Cloud AWS (Deuna!)

Solución de las cuatro tareas del caso: gestión de infraestructura como código y ambientes de nube AWS para una fintech de alto volumen transaccional.

Cada tarea tiene su carpeta y su `README.md` con el diseño completo. Este documento es el punto de entrada: resume cada tarea, indica el orden de lectura y deja claro qué se verificó y qué no.

## Cómo revisar

| Orden | Tarea | Empezar por | Tiempo de lectura |
|---|---|---|---|
| 1 | [Tarea 3 — Terraform](tarea-3-terraform-iac/README.md) | `README.md`, luego `environments/production/main.tf` y `modules/` | 20 min |
| 2 | [Tarea 1 — Monitoreo ECS](tarea-1-monitoreo-ecs/README.md) | `README.md`, luego `lambda/capacity_monitor.py` | 15 min |
| 3 | [Tarea 2 — Costeo](tarea-2-costeo-transaccion/README.md) | `README.md` (sección 3, ejemplo de un día) | 15 min |
| 4 | [Tarea 4 — Incidente](tarea-4-incidente-produccion/README.md) | `README.md` completo | 10 min |

La tarea 3 va primero porque concentra el mayor peso de la evaluación (código Terraform y seguridad) y porque las otras tres la referencian: su pipeline despliega el monitor de la tarea 1, sus tags alimentan el costeo de la tarea 2 y su rol `dba-break-glass` aparece en el incidente de la tarea 4.

## Estructura

```text
deuna-caso-practico/
├── README.md                        este documento
├── ruff.toml                        reglas de calidad de Python (todo el repo)
├── .markdownlint-cli2.yaml          reglas de formato de la documentación
├── .github/workflows/               un pipeline por tarea + code-quality
├── tarea-1-monitoreo-ecs/
│   ├── README.md                    diseño: detección, integración, alerta, ruido, dashboard
│   ├── lambda/                      detector en Python y 22 pruebas
│   ├── terraform/                   módulo que despliega el detector
│   └── examples/                    eventos reales generados por el código
├── tarea-2-costeo-transaccion/
│   ├── README.md                    diseño: etiquetado, atribución, herramientas, pipeline, presentación
│   ├── sql/                         5 vistas de Athena
│   ├── catalog/                     catálogo de componentes
│   └── tests/                       8 pruebas en DuckDB
├── tarea-3-terraform-iac/
│   ├── README.md                    estructura, estado remoto, pipeline, validaciones, decisiones
│   ├── environments/                una carpeta por ambiente: development, sandbox, production
│   ├── modules/                     un módulo por servicio, cada uno con sus pruebas
│   └── tests/                       19 pruebas de terraform test
└── tarea-4-incidente-produccion/
    └── README.md                    diagnóstico, mitigación, comunicación, postmortem
```

## Resumen por tarea

### Tarea 1 — Monitoreo de escalamiento en ECS

AWS no emite un evento cuando un servicio llega a su máximo de tareas. Una **Lambda que corre cada minuto** compara el máximo de cada scalable target con el `desiredCount` del servicio, y descubre sola los servicios nuevos.

- **Detección:** estados `OK`, `WARNING` (80 % del máximo) y `AT_MAX`. Consulta las actividades "no escaladas" de Auto Scaling para saber si el máximo está **bloqueando** demanda real.
- **Integración:** una línea JSON por evento en un log group dedicado. La herramienta externa la ingiere por el canal que ya usa, CloudWatch Logs, sin depender de su API.
- **Alerta:** severidad según la criticidad del servicio, `dedup_key`, capacidad, CPU, memoria, duración y enlaces al runbook.
- **Ruido:** 5 minutos antes de alertar, 10 de histéresis para resolver, eventos solo en transiciones, agregación por cluster y servicios de tamaño fijo excluidos. Una saturación de una hora genera 3 alertas, no 60.
- **Respaldo:** alarmas de CloudWatch por si falla la herramienta externa o el propio detector.
- **Costo:** unos USD 2–5 al mes en AWS para 100 servicios.

### Tarea 2 — Costeo por tipo de transacción

Los tags de AWS funcionan por recurso, no por petición. La solución cruza **CUR 2.0** (cuánto costó cada recurso) con **telemetría** (cuánto usó cada tipo de transacción).

- **Propagación:** el tipo se asigna en API Gateway según la ruta, del lado del servidor, y viaja en headers HTTP, atributos de SQS y en cada línea de log.
- **Simple:** cinco servicios administrados (CUR, Firehose, Athena, QuickSight y los tags de costo). Sin orquestador ni tablas intermedias: el cálculo son vistas SQL.
- **Atribución en tres capas:** directa (recursos dedicados), por uso (proporción medida de requests, tiempo de base, GB-s, bytes) y overhead (lo que no se puede medir, en proporción al resto).
- **Controles:** el día no se publica si lo atribuido no cuadra con la factura, o si el overhead pasa del 20 %.
- **Ejemplo verificado:** USD 1,05 por cada 1 000 transacciones monetarias contra USD 0,17 por cada 1 000 no monetarias. Aurora explica el 57 % del costo monetario.

### Tarea 3 — Terraform

Una carpeta por ambiente (`environments/<ambiente>/`) y un módulo por servicio (`modules/<servicio>/`). Las carpetas de ambiente solo pasan valores al módulo de composición, así que los tres ambientes ejecutan el mismo código.

- **KMS:** la policy separa administrar de usar. Nadie tiene `kms:*` y el uso solo se permite a través de S3, RDS y Secrets Manager.
- **S3:** bucket policy hecha solo de denegaciones (sin TLS, otra llave, ACL). Lifecycle por niveles y Object Lock en producción.
- **Aurora:** subnets privadas, ingreso solo por security group, TLS forzado, `pgaudit`, Performance Insights y Enhanced Monitoring.
- **Secrets Manager:** rotación automática con la Lambda oficial de AWS, sin salida a internet. Un `Deny` explícito bloquea el valor a todo principal fuera de la lista.
- **La contraseña de `pgadmin` nunca entra al estado:** recurso efímero y atributos write-only.
- **Auditoría:** CloudTrail multi-región con validación de integridad, bucket y llave propios con Object Lock. Solo los eventos sensibles (lectura del secreto, cambios a llaves y policies, intentos de apagar el trail) salen hacia la herramienta de observabilidad.
- **GitHub:** estado en S3 con lock nativo, un bucket por cuenta de ambiente. Acceso a AWS por OIDC de GitHub Actions, sin llaves.
- **Pipeline:** `validate → security → test → plan → development → sandbox → production`. El despliegue a sandbox y el de producción son jobs separados. Producción exige que pasen todos los análisis y el despliegue a sandbox, y además la aprobación del GitHub Environment `production`.

### Tarea 4 — Incidente en producción

La idea central: **10/10 tareas es un síntoma, no la causa**. Si el servicio espera a la base o a un proveedor externo, subir el máximo lo empeora.

- **Diagnóstico** en tres ramas, según dónde se va el tiempo en los traces: la aplicación, Aurora o la dependencia externa. Con los comandos y las consultas SQL listos para usar.
- **Mitigación sin downtime** según la causa. Incluye qué **no** hacer en caliente, y cómo reconciliar con Terraform un cambio de emergencia.
- **Fintech:** pagos en estado incierto. El incidente no termina hasta conciliar cada transacción afectada.
- **Comunicación:** plantillas para el equipo técnico, producto y C-Level, con frecuencia y canal para cada audiencia.
- **Postmortem** sin culpables, con diez acciones concretas para detectar, mitigar y prevenir.

## Cómo se cubren los ejes de evaluación

| Eje | Dónde se ve |
|---|---|
| **Costo-eficiencia** | Serverless v2 fuera de producción y Graviton en producción, Bucket Key, lifecycle por niveles (T3). Métricas por cluster y no por servicio, snapshots espaciados (T1). Costo por transacción con palancas concretas (T2). Costo de cada mitigación (T4) |
| **Seguridad** | Mínimo privilegio en KMS, S3 y Secrets Manager. OIDC sin llaves. Secretos fuera del estado. CloudTrail inmutable con llave y bucket propios. Cinco escáneres en el pipeline. Tipo de transacción asignado del lado del servidor (T2). Acceso auditado a la base (T4) |
| **Operación** | Todo en Terraform con el mismo pipeline. Descubrimiento automático de servicios (T1). Costeo sin pipeline que mantener: vistas que se recalculan solas, con controles de calidad (T2). Deriva de cambios de emergencia (T4) |
| **Observabilidad** | Alertas con contexto para actuar, deduplicación, respaldo y vigilancia del propio detector (T1). Dashboards de guardia y de costos (T1, T2). Diagnóstico guiado por traces (T4) |

## Pipelines (GitHub Actions)

Un solo repositorio, un pipeline por tarea y uno transversal de calidad. Cada pipeline de tarea solo corre cuando cambia su carpeta (`paths`), así que un cambio en la tarea 2 no dispara un plan de Terraform de la tarea 3.

| Workflow | Cuándo corre | Qué hace |
|---|---|---|
| `code-quality.yml` | Todo PR y push a `main`, sin filtro de rutas | `ruff check` y `ruff format --check` sobre todo el Python, `markdownlint` sobre todos los README, `actionlint` sobre los workflows |
| `tarea-1-monitoreo.yml` | Cambios en `tarea-1-monitoreo-ecs/` | 22 pruebas del detector (Python 3.13, el runtime de la Lambda). `fmt`, `validate`, `tflint`, `checkov` y `trivy` sobre el módulo Terraform. No despliega: el módulo lo consume cada cuenta |
| `tarea-2-costeo.yml` | Cambios en `tarea-2-costeo-transaccion/` | Ejecuta las vistas SQL en DuckDB (8 pruebas) |
| `tarea-3-terraform.yml` | Cambios en `tarea-3-terraform-iac/` | Validación, seguridad, pruebas y plan de los tres ambientes. En `main`, despliegue development → sandbox → production con aprobación (`tarea-3-terraform-apply.yml`) |
| `tarea-4-incidente.yml` | Cambios en `tarea-4-incidente-produccion/` | Formato del runbook y enlaces internos sin romper (`lychee`) |

Para que nada llegue a `main` sin pasar los controles, la protección de la rama exige los checks de `code-quality` y los de cada tarea. Los checks de tarea que no corren por `paths` no bloquean el merge.

Todos los workflows usan `permissions: contents: read` por defecto. Solo los jobs de plan y apply de la tarea 3 piden `id-token: write` para OIDC.

## Verificación

Todo lo siguiente se ejecutó en local con Terraform 1.17.2 y el provider AWS 6.73.0:

| Qué | Resultado |
|---|---|
| T3: `terraform fmt`, `validate` y `test` | 15 de 15 pasaban antes de agregar `modules/audit` y migrar a GitHub; repetir |
| T3: `tflint`, `checkov`, `trivy` | Sin hallazgos. Tres excepciones de Checkov justificadas en el código |
| Workflows de GitHub Actions | `actionlint` 1.7.8 sin hallazgos en los seis workflows |
| Python de todo el repo: `ruff check` y `ruff format --check` (ruff 0.17.5) | Sin hallazgos |
| Documentación: `markdownlint-cli2` | Sin hallazgos |
| T1: pruebas del detector (Python) | 22 de 22 pasan |
| T1: módulo Terraform: `validate`, `tflint`, `checkov`, `trivy` | Sin hallazgos. Siete excepciones de Checkov justificadas en el código |
| T2: vistas SQL en DuckDB | 8 de 8 pruebas pasan; los valores coinciden con el cálculo manual |
| Todo el repositorio: `gitleaks` | Sin secretos |

**No verificado**, porque requiere una cuenta AWS y un repositorio GitHub configurado:

- `terraform plan` y `apply` contra AWS, y la ejecución del pipeline en GitHub Actions.
- El detector de la tarea 1 contra APIs reales. Sus pruebas usan dobles de prueba.
- Las vistas de la tarea 2 contra un export real de CUR 2.0 en Athena. El Terraform de la tarea 2 está descrito, no implementado.
- Algunos nombres de parámetros tomados de la documentación de AWS. Cada `README` los lista.

## Supuestos

- **GitHub es la plataforma** de código y despliegue: repositorio público y pipeline en GitHub Actions.
- **Una cuenta AWS por ambiente**, región `us-east-1`.
- **La red ya existe**: VPC, subnets privadas, security groups de las aplicaciones y un VPC endpoint de Secrets Manager.
- **La herramienta de observabilidad externa** es genérica (por ejemplo Datadog, New Relic o Grafana) y ya ingiere CloudWatch Logs.
- **Las cuentas, VPC, subnets, roles y URL** de los ejemplos son marcadores y deben reemplazarse.
- **Horas en Ecuador (UTC−5)** en la tarea 4.

## Cómo ejecutar las verificaciones

```sh
# Tarea 3: pruebas por módulo y validación por ambiente
cd tarea-3-terraform-iac
for m in modules/*/; do (cd "$m" && terraform init -backend=false && terraform test); done
for e in environments/*/; do (cd "$e" && terraform init -backend=false && terraform validate); done

# Tarea 1
cd tarea-1-monitoreo-ecs/lambda && python -m unittest discover -s tests
cd ../terraform && terraform init -backend=false && terraform validate

# Tarea 2
cd tarea-2-costeo-transaccion
pip install -r requirements-dev.txt && python -m unittest discover -s tests

# Calidad (desde la raíz)
ruff check . && ruff format --check .
npx markdownlint-cli2 "**/*.md" "#**/.terraform"
```

Ninguna de estas verificaciones necesita credenciales de AWS.
