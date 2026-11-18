# Tarea 3 — Infraestructura de datos con Terraform

Repositorio Terraform que provisiona, para tres ambientes (`development`, `sandbox`, `production`):

| Recurso | Módulo | Puntos clave |
|---|---|---|
| Llave KMS simétrica | `modules/kms` | Key policy sin `kms:*`, rotación automática, tags de clasificación |
| Bucket S3 | `modules/s3` | SSE-KMS con Bucket Key, policy de solo denegaciones, versionado, lifecycle, sin acceso público |
| Aurora PostgreSQL | `modules/aurora` | Cifrado KMS, subnets privadas, ingreso solo por security group, backups, Performance Insights y Enhanced Monitoring |
| Secreto `pgadmin` | `modules/secrets` | Cifrado KMS, rotación automática por Lambda, resource policy con lista de acceso |
| Auditoría | `modules/audit` | CloudTrail multi-región con validación de integridad, bucket y llave propios, Object Lock, copia filtrada hacia la herramienta de observabilidad |

Está pensado para ejecutarse en GitHub: el estado vive en S3 y el despliegue lo hace GitHub Actions (`.github/workflows/tarea-3-terraform.yml` en la raíz del repositorio).

## Estructura

Separada por carpeta: **un ambiente por carpeta** en `environments/` y **un servicio por módulo** en `modules/`, cada módulo con la estructura estándar de Terraform y sus propias pruebas.

```text
tarea-3-terraform-iac/
├── environments/                   Una raíz por ambiente: aquí se ejecuta plan y apply
│   ├── development/
│   │   ├── backend.tf              Estado S3 de la cuenta de development
│   │   ├── providers.tf            Provider AWS, cuenta permitida, tags por defecto
│   │   ├── versions.tf             Versiones de Terraform y providers
│   │   ├── main.tf                 Llamada a modules/data-platform con los valores del ambiente
│   │   ├── variables.tf            Vacío: los valores viven en main.tf
│   │   ├── outputs.tf
│   │   └── .terraform.lock.hcl     Versiones y hashes de providers fijados
│   ├── sandbox/                    Misma estructura
│   └── production/                 Misma estructura
├── modules/
│   ├── data-platform/              Composición: conecta los módulos de servicio
│   ├── kms/                        Llave de cifrado
│   ├── s3/                         Bucket de datos
│   ├── aurora/                     Cluster Aurora PostgreSQL
│   ├── secrets/                    Secreto pgadmin y su rotación
│   └── audit/                      CloudTrail y evidencia de auditoría
│       ├── main.tf  variables.tf  outputs.tf  versions.tf
│       └── tests/                  Pruebas del módulo (terraform test)
├── .tflint.hcl  .checkov.yaml  .trivyignore
└── README.md
```

Fuera de esta carpeta, en la raíz del repositorio: `.github/workflows/tarea-3-terraform*.yml` (pipeline), `.pre-commit-config.yaml` y `.gitignore`, compartidos por las cuatro tareas.

### Por qué esta estructura

**Un ambiente, una carpeta.** Cada carpeta de `environments/` es una raíz independiente con su backend, su provider y su lock file. Un `terraform apply` en `environments/development` no puede tocar el estado ni la cuenta de producción: el backend apunta a otro bucket y `allowed_account_ids` rechaza cualquier otra cuenta. Se ve en el árbol qué existe en cada ambiente, y el pipeline trabaja sobre una carpeta concreta.

**Carpetas delgadas, lógica en los módulos.** Las carpetas de ambiente no tienen recursos: solo llaman a `modules/data-platform` con sus valores. Así los tres ambientes ejecutan el mismo código y no divergen con el tiempo. Lo que se probó en sandbox es lo que llega a producción; la única diferencia posible está en los valores de `main.tf`, que se revisan en el pull request.

**Un módulo por servicio**, cada uno con la estructura estándar (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `tests/`), variables validadas, valores seguros por defecto y sin bloques `provider` ni `backend`. `data-platform` solo conecta módulos.

**Tres barreras de aislamiento** entre ambientes: un estado por ambiente, una cuenta AWS por ambiente y un rol IAM por ambiente.

Si el número de stacks crece, el siguiente paso es mover los módulos a repositorios propios con tags de versionado semántico (`git::https://github.com/...?ref=v1.2.0`), para que cada ambiente fije la versión que consume y pueda promoverla de forma explícita.

## Estado remoto

El estado se guarda en **S3 con locking nativo** (`use_lockfile = true`, disponible desde Terraform 1.10). No hace falta tabla DynamoDB para el lock.

- `environments/<ambiente>/backend.tf` declara bucket, key y región de ese ambiente. No hay credenciales en el repositorio: el acceso es el del rol OIDC del job.
- **Un estado por ambiente**, en un bucket dentro de la cuenta de ese ambiente. Un error en un ambiente no puede dañar el estado de otro, y el rol de un ambiente no puede leer el estado de otro.
- **Locking** con un objeto `.tflock` en el mismo bucket, más `concurrency` por ambiente en el workflow para que dos jobs no compitan por el mismo estado.
- El bucket de estado (creado fuera de este stack, una vez por cuenta) debe tener: versionado, cifrado SSE-KMS, bloqueo de acceso público, policy que exige TLS y acceso solo para los roles de plan y apply. El versionado permite recuperar una versión anterior del estado.
- **La contraseña de `pgadmin` no está en el estado.** Se genera con un recurso efímero y se envía con atributos write-only (`master_password_wo`, `secret_string_wo`), disponibles desde Terraform 1.11. Aun así el estado se trata como dato sensible, porque describe la topología.

Para trabajar en local contra el estado de un ambiente (con credenciales de AWS SSO del ambiente):

```sh
aws sso login --profile deuna-development
export AWS_PROFILE=deuna-development
cd environments/development
terraform init
terraform plan
```

## Pipeline

```text
pull request         validate ─ security ─ test ─ plan (3 ambientes)
rama main            validate ─ security ─ test ─ plan ─ apply development ─ apply sandbox ─ apply production
                                                          automático          automático      aprobación del Environment
```

| Etapa | Job | Qué verifica |
|---|---|---|
| validate | `fmt` | Formato canónico |
| validate | `validate` | Sintaxis, tipos y referencias en las tres carpetas de ambiente |
| validate | `tflint` | Errores del provider AWS, variables sin uso, convenciones |
| security | `checkov` | Configuración insegura en el código y secretos |
| security | `trivy` | Segunda opinión de configuración insegura (reglas distintas) |
| security | `gitleaks` | Secretos en todo el historial de Git |
| test | `terraform-test (<módulo>)` | Pruebas de cada módulo en su carpeta (matriz de seis módulos, 19 pruebas) |
| plan | `plan (<ambiente>)` | Plan real en `environments/<ambiente>` (matriz), con rol de solo lectura. El resumen de cambios aparece en el resumen del run |
| plan | `plan (production)` | Además, reglas de Checkov sobre el plan de producción ya resuelto |
| deploy | `apply-development` | Aplica el plan guardado |
| deploy | `apply-sandbox` | Job propio. Corre solo si development terminó bien |
| deploy | `apply-production` | Job propio y con aprobación. Ver abajo |

Los tres apply llaman al mismo workflow reutilizable (`tarea-3-terraform-apply.yml`): el código del despliegue es idéntico en los tres ambientes.

### Controles del despliegue a producción

`apply-production` solo se puede ejecutar cuando se cumplen todas estas condiciones:

1. Todos los jobs de validate, security, test y los tres planes terminaron bien. `apply-development` los declara en `needs` y la cadena `development → sandbox → production` hereda la condición.
2. El Checkov sobre el plan de producción pasó (es un paso del job `plan (production)`).
3. `apply-sandbox` terminó bien: el mismo commit ya se desplegó en sandbox.
4. El evento es un push a `main` (los PR nunca llegan a los jobs de deploy).
5. El GitHub Environment `production` exige la aprobación de revisores antes de que el job arranque.

El job aplica el archivo de plan que se generó en el mismo run, no un plan nuevo. Si el estado cambió entre el plan y la aprobación, Terraform rechaza el plan por obsoleto.

**El plan viaja cifrado.** El repositorio es público y en un repositorio público cualquiera puede descargar los artefactos de un run. El job de plan cifra el archivo con AES-256 (`openssl`, clave en el secreto `TF_PLAN_PASSPHRASE`) y solo lo publica en `main`; en un PR solo se publican los conteos de create/update/delete.

### Configuración necesaria en GitHub

Lo siguiente se configura en el repositorio; no se puede expresar en el workflow.

- **Environments** (Settings → Environments): `development`, `sandbox` y `production`. Cada uno con la variable `AWS_APPLY_ROLE_ARN` del rol de escritura de su cuenta y con *Deployment branches* limitado a `main`.
- **Environment `production`**: *Required reviewers* (idealmente dos personas) y *Prevent self-review*, para que quien hizo el cambio no lo apruebe. En un repositorio público está disponible en el plan Free.
- **Variables del repositorio** (Settings → Secrets and variables → Actions → Variables): `AWS_PLAN_ROLE_ARN_development`, `AWS_PLAN_ROLE_ARN_sandbox`, `AWS_PLAN_ROLE_ARN_production`. Son ARN, no secretos.
- **Secreto del repositorio** `TF_PLAN_PASSPHRASE`: clave para cifrar el plan entre el job de plan y el de apply.
- **Protección de `main`** (ruleset): sin push directo, pull request con aprobación obligatoria y status checks requeridos (`fmt`, `validate`, `tflint`, `checkov`, `trivy`, `gitleaks`, `terraform-test`, `plan (…)`).
- **Actions**: en Settings → Actions → General, *Workflow permissions* en solo lectura y aprobación obligatoria para workflows de colaboradores externos.

| Configuración | Dónde | Uso |
|---|---|---|
| `AWS_PLAN_ROLE_ARN_<ambiente>` | Variable del repositorio | Rol de solo lectura para `plan`. Disponible en PR |
| `AWS_APPLY_ROLE_ARN` | Variable de cada Environment | Rol de escritura para `apply`. Solo dentro del Environment |
| `TF_PLAN_PASSPHRASE` | Secreto del repositorio | Cifrado del plan |

### Acceso a AWS sin llaves estáticas

Cada job pide un token OIDC a GitHub (`permissions: id-token: write`) y `aws-actions/configure-aws-credentials` asume un rol con `AssumeRoleWithWebIdentity`. Las credenciales duran lo que dura el job.

La trust policy del rol de escritura acepta solo jobs que corren dentro del Environment de ese ambiente. Como el Environment solo admite `main` y, en producción, exige aprobación, el rol hereda esos controles:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<cuenta>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:deuna/data-platform:environment:production"
    }
  }
}
```

El rol de solo lectura acepta `repo:deuna/data-platform:pull_request` y `repo:deuna/data-platform:ref:refs/heads/main`. Un pull request puede planificar, pero no modificar nada. Los PR desde forks no reciben token OIDC, así que el workflow omite el plan para ellos.

## Validación de seguridad antes del apply

| Herramienta | Momento | Para qué |
|---|---|---|
| `terraform fmt` y `validate` | pre-commit, pipeline | Errores básicos |
| `tflint` con el ruleset de AWS | pre-commit, pipeline | Valores que el provider rechazaría, código muerto |
| `checkov` | pre-commit, pipeline, plan de producción | Benchmarks de seguridad (CIS, PCI) sobre código y sobre el plan |
| `trivy config` | pre-commit, pipeline | Segundo motor de reglas |
| `gitleaks` | pre-commit, pipeline | Secretos en el historial |
| `terraform test` | pipeline | Afirmaciones propias: por ejemplo, que ningún statement de la key policy otorga `kms:*` |

Dos motores de reglas porque no encuentran lo mismo: Trivy detectó una salida a internet en la Lambda de rotación que Checkov no marcó. Se corrigió enrutando la Lambda al VPC endpoint de Secrets Manager.

Las excepciones aceptadas están en `.checkov.yaml`, cada una con su justificación.

## Decisiones de diseño

**KMS.** La policy separa administración de uso: quien administra la llave no puede descifrar. El uso se concede solo a través de S3, RDS y Secrets Manager (`kms:ViaService`) y solo a principals de la cuenta. La cuenta raíz conserva la administración como recuperación, sin permisos criptográficos.

**S3.** La bucket policy contiene solo denegaciones: sin TLS, TLS anterior a 1.2, cifrado distinto de KMS, otra llave KMS y cambios de ACL. El acceso se concede por IAM, nunca desde el bucket. Producción activa Object Lock en modo COMPLIANCE por siete años.

**Aurora.** El security group no tiene reglas de salida y solo admite el puerto 5432 desde los security groups declarados. El parameter group fuerza TLS y activa `pgaudit` para DDL y cambios de roles. Las sentencias de datos no se registran, para no llevar información financiera a los logs.

**Secrets Manager.** Un `Deny` explícito bloquea la lectura y la escritura del valor a todo principal fuera de la lista, incluidos los administradores de la cuenta. La Lambda de rotación es la aplicación oficial de AWS y no tiene salida a internet.

**Auditoría.** Ver la sección siguiente.

**Costo.**

| Decisión | Efecto |
|---|---|
| Development y sandbox en Aurora Serverless v2 desde 0.5 ACU | Pagan por uso; sin instancias ociosas fuera de horario |
| Producción aprovisionada sobre Graviton (`db.r6g`) | Mejor precio por rendimiento y apta para Reserved Instances |
| S3 Bucket Key | Reduce las llamadas a KMS, que se cobran por petición |
| Lifecycle: Standard → Standard-IA (30 días) → Glacier Instant Retrieval (90 días) | Baja el costo de almacenamiento sin perder acceso inmediato |
| Expiración de versiones no actuales y de cargas multiparte incompletas | Evita pagar por datos que nadie ve |
| Una sola llave KMS para el stack | Un cargo mensual en lugar de tres, con el mismo aislamiento por `ViaService` |
| Performance Insights a 7 días fuera de producción | Nivel sin costo |
| Eventos de datos de S3 solo de escritura fuera de producción | Las lecturas son la mayoría de los eventos y se cobran por evento |
| Solo los eventos sensibles salen hacia la herramienta externa | La herramienta cobra por GB ingerido; el resto queda en S3 a costo de almacenamiento |
| Retención de logs y backups reducida fuera de producción | Menos almacenamiento |

## Auditoría

El eje de seguridad pide auditoría, y la tarea 4 usa el rol `dba-break-glass`. Hace falta poder responder después quién leyó el secreto, quién usó la llave y quién tocó los datos. `modules/audit` cubre eso.

```text
CloudTrail (multi-región, validación de integridad)
   ├── S3 de auditoría ──────── evidencia de largo plazo: Object Lock, lifecycle a Glacier IR
   └── CloudWatch Logs ─ subscription filter (solo eventos sensibles) ─> herramienta de observabilidad
```

### Qué se registra

| Pregunta | Evento |
|---|---|
| ¿Quién leyó la contraseña de `pgadmin`? | `secretsmanager:GetSecretValue` (management event) |
| ¿Quién usó la llave de datos? | `kms:Decrypt`, `GenerateDataKey` (management events) |
| ¿Quién leyó o escribió objetos del bucket de datos? | Eventos de datos de S3, limitados a ese bucket |
| ¿Quién cambió policies, llaves o el propio trail? | Management events |
| ¿Qué hizo alguien dentro de la base? | `pgaudit` en CloudWatch Logs (módulo `aurora`) |

### Por qué así

- **Llave y bucket propios.** Quien administra o lee los datos no puede alterar ni leer la evidencia de lo que hizo. La llave de auditoría solo la usa este trail (`aws:SourceArn`) y solo la descifran los roles de `audit_reader_role_arns`. La bucket policy deniega la lectura a cualquier otro principal, aunque tenga `s3:GetObject` por IAM.
- **Inmutable.** Object Lock en modo COMPLIANCE: siete años en producción, uno en sandbox. Además, `enable_log_file_validation` firma archivos digest que prueban que ningún log se alteró ni se borró (`aws cloudtrail validate-logs`).
- **CloudWatch como canal, no como herramienta.** La herramienta principal es externa e ingiere CloudWatch Logs. El trail escribe ahí y un subscription filter envía solo los eventos sensibles: lectura del secreto, cambios a llaves, buckets o al trail, `AccessDenied*` y uso de root. Si la herramienta ya suscribe log groups por prefijo, `observability_log_destination_arn` queda en `null`.
- **Sin DynamoDB.** No aporta inmutabilidad ni consultas baratas para auditoría, y el lock del estado ya usa S3.
- **Consultas.** La evidencia en S3 se consulta con Athena (tabla de CloudTrail con partition projection) cuando una investigación necesita más de lo que se envió a la herramienta.

Las alertas viven en la herramienta externa. Como mínimo: lectura del secreto por un principal distinto de la aplicación y de la Lambda de rotación, cualquier evento de `dba-break-glass`, intentos de `StopLogging`/`DeleteTrail`, uso de root y la ausencia de eventos del trail durante 15 minutos (el trail dejó de entregar).

## Supuestos

- La red ya existe. `vpc_id`, subnets privadas y security groups llegan como variables.
- La VPC tiene un **VPC endpoint de interfaz de Secrets Manager**. La Lambda de rotación lo necesita porque no tiene salida a internet.
- Hay una cuenta AWS por ambiente.
- Los identificadores en `environments/*/main.tf` y `backend.tf` (cuentas, VPC, subnets, roles, buckets de estado) son marcadores y deben reemplazarse.
- GitHub es la plataforma de código y despliegue (el enunciado pide un repositorio público en GitHub).
- El bucket de estado de cada cuenta existe antes del primer `init` (se crea una vez, fuera de este stack).
- El trail de este stack complementa, no reemplaza, un trail de organización si existe. Si la organización ya entrega los management events, el selector de management de `modules/audit` se puede retirar para no pagar una segunda copia.

## Qué se verificó y qué no

Verificado en local con Terraform 1.17.2 y provider AWS 6.73.0:

- `terraform fmt -check` y `terraform validate`: sin errores.
- `terraform test`: 15 de 15 pruebas pasaban antes de agregar `modules/audit` (que suma 4).
- `tflint` 0.66.0, `trivy` 0.76.2 y `checkov` 3.4.5: sin hallazgos. Checkov tiene tres excepciones justificadas: dos en `.checkov.yaml` y una en línea en `modules/secrets/main.tf`.
- `gitleaks` 8.30.1: sin secretos.
- Workflows de GitHub Actions: YAML válido y dependencias entre jobs consistentes.

No verificado, porque requiere una cuenta AWS y un repositorio GitHub configurado:

- `terraform plan` y `apply` contra AWS.
- La ejecución del pipeline en GitHub Actions.
- Los nombres de parámetros de la aplicación de rotación del Serverless Application Repository (`kmsKeyArn`, `vpcSubnetIds`, `vpcSecurityGroupIds`), tomados de la documentación de AWS.
- La reestructura por carpetas (ambientes en `environments/<ambiente>/`, pruebas dentro de cada módulo), el backend S3 y el módulo `audit` no se ejecutaron todavía: repetir `terraform validate`, `terraform test`, `tflint`, `checkov` y `trivy`. Los `.terraform.lock.hcl` de cada ambiente son copia del lock anterior (mismos providers).
- La cabecera de cifrado con la que CloudTrail entrega los archivos digest. Por eso el bucket de auditoría no exige la cabecera de KMS (`enforce_kms_headers = false`) y confía en el cifrado por defecto.

## Uso local

```sh
# Desde la raíz del repositorio: mismas verificaciones que el pipeline
pre-commit install

# Pruebas de un módulo (no necesitan credenciales de AWS)
cd tarea-3-terraform-iac/modules/kms
terraform init -backend=false && terraform test

# Validar un ambiente
cd ../../environments/development
terraform init -backend=false && terraform validate
```
