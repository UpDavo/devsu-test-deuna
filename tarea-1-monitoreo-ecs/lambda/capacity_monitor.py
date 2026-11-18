"""Monitor de capacidad máxima de servicios ECS.

Corre cada minuto. Para cada servicio ECS con auto scaling en la cuenta y región:

1. Lee min y max del scalable target, y desired, running y pending del servicio.
2. Clasifica el servicio: OK, WARNING (poco margen) o AT_MAX.
3. Compara con el estado anterior, guardado en DynamoDB, y emite eventos JSON
   solo en transiciones y recordatorios. Así una saturación de una hora genera
   tres o cuatro líneas, no sesenta.
4. Emite cada cierto tiempo un snapshot por servicio para los dashboards.

Cada línea es un JSON en stdout. Lambda la escribe en un log group propio, la
herramienta de observabilidad externa la ingiere desde CloudWatch Logs, y las
líneas de resumen por cluster llevan formato EMF: CloudWatch extrae de ellas
una métrica que sirve de respaldo si la herramienta externa falla.
"""

from __future__ import annotations

import json
import math
import os
import time
from dataclasses import asdict, dataclass, field, replace
from datetime import UTC, datetime

SCHEMA_VERSION = "1.0"
EVENT_PREFIX = "ecs.capacity."

STATUS_OK = "OK"
STATUS_WARNING = "WARNING"
STATUS_AT_MAX = "AT_MAX"

# Severidad de la alerta accionable según el tag "criticality" del servicio.
SEVERITY_BY_CRITICALITY = {"tier-1": "critical", "tier-2": "high", "tier-3": "medium"}
SEVERITY_ORDER = ["info", "low", "medium", "high", "critical"]


# --- Modelo ----------------------------------------------------------------


@dataclass(frozen=True)
class Config:
    environment: str = "production"
    warning_ratio: float = 0.8
    sustain_seconds: int = 300
    recovery_seconds: int = 600
    renotify_seconds: int = 1800
    snapshot_interval_seconds: int = 300
    cluster_saturation_threshold: int = 3
    state_table: str = ""
    dashboard_url: str = ""
    runbook_url: str = ""

    @classmethod
    def from_env(cls, env: dict | None = None) -> Config:
        env = os.environ if env is None else env
        return cls(
            environment=env.get("ENVIRONMENT", cls.environment),
            warning_ratio=float(env.get("WARNING_RATIO", cls.warning_ratio)),
            sustain_seconds=int(env.get("SUSTAIN_SECONDS", cls.sustain_seconds)),
            recovery_seconds=int(env.get("RECOVERY_SECONDS", cls.recovery_seconds)),
            renotify_seconds=int(env.get("RENOTIFY_SECONDS", cls.renotify_seconds)),
            snapshot_interval_seconds=int(
                env.get("SNAPSHOT_INTERVAL_SECONDS", cls.snapshot_interval_seconds)
            ),
            cluster_saturation_threshold=int(
                env.get("CLUSTER_SATURATION_THRESHOLD", cls.cluster_saturation_threshold)
            ),
            state_table=env.get("STATE_TABLE", ""),
            dashboard_url=env.get("DASHBOARD_URL", ""),
            runbook_url=env.get("RUNBOOK_URL", ""),
        )


@dataclass(frozen=True)
class ServiceSnapshot:
    cluster: str
    service: str
    min_capacity: int
    max_capacity: int
    desired: int
    running: int
    pending: int
    tags: dict = field(default_factory=dict)
    # Se completan solo para servicios en el máximo.
    demand_exceeds_max: bool | None = None
    cpu_avg_5m: float | None = None
    memory_avg_5m: float | None = None

    @property
    def key(self) -> str:
        return f"{self.cluster}/{self.service}"

    @property
    def resource_id(self) -> str:
        return f"service/{self.cluster}/{self.service}"

    @property
    def utilization_pct(self) -> float:
        if self.max_capacity <= 0:
            return 0.0
        return round(100.0 * self.desired / self.max_capacity, 1)


@dataclass(frozen=True)
class ServiceState:
    status: str = STATUS_OK
    since: int = 0  # instante en que entró al estado actual
    alerted_at: int = 0  # última alerta accionable emitida; 0 = ninguna abierta
    below_max_since: int = 0  # inicio de la ventana de recuperación


# --- Lógica pura (sin AWS) -------------------------------------------------


def classify(snap: ServiceSnapshot, cfg: Config) -> str:
    """Clasifica un servicio según su margen de escalamiento."""
    # Un servicio de tamaño fijo (min == max) está siempre "en el máximo" por
    # diseño. Alertar sobre él sería ruido permanente.
    if snap.max_capacity <= snap.min_capacity:
        return STATUS_OK
    if snap.desired >= snap.max_capacity:
        return STATUS_AT_MAX
    if snap.desired >= math.ceil(snap.max_capacity * cfg.warning_ratio):
        return STATUS_WARNING
    return STATUS_OK


def evaluate(
    snap: ServiceSnapshot, prev: ServiceState | None, now: int, cfg: Config
) -> tuple[ServiceState, list[str]]:
    """Calcula el nuevo estado y los eventos a emitir.

    Eventos:
      max_reached    el servicio llegó al máximo. Informativo, no pagina.
      max_sustained  sigue en el máximo tras sustain_seconds. Alerta accionable.
                     Se repite cada renotify_seconds mientras dure.
      max_recovered  pasó recovery_seconds por debajo del máximo. Resuelve la alerta.
      headroom_low   entró en la franja de advertencia. Aviso temprano.
    """
    prev = prev or ServiceState(status=STATUS_OK, since=now)
    current = classify(snap, cfg)
    events: list[str] = []

    if current == STATUS_AT_MAX:
        if prev.status != STATUS_AT_MAX:
            return ServiceState(status=STATUS_AT_MAX, since=now), ["max_reached"]

        # Sigue en el máximo (o volvió durante la ventana de recuperación,
        # en cuyo caso la saturación se considera continua: evita el flapping).
        state = replace(prev, below_max_since=0)
        first_alert_due = state.alerted_at == 0 and now - state.since >= cfg.sustain_seconds
        renotify_due = state.alerted_at and now - state.alerted_at >= cfg.renotify_seconds
        if first_alert_due or renotify_due:
            events.append("max_sustained")
            state = replace(state, alerted_at=now)
        return state, events

    if prev.status == STATUS_AT_MAX:
        # Histéresis: no se declara recuperado hasta pasar recovery_seconds
        # continuos por debajo del máximo.
        below_since = prev.below_max_since or now
        if now - below_since >= cfg.recovery_seconds:
            return ServiceState(status=current, since=now), ["max_recovered"]
        return replace(prev, below_max_since=below_since), []

    if current != prev.status:
        if current == STATUS_WARNING:
            events.append("headroom_low")
        return ServiceState(status=current, since=now), events

    return prev, []


def severity_for(event: str, snap: ServiceSnapshot, cluster_saturated: bool) -> str:
    if event == "max_sustained":
        severity = SEVERITY_BY_CRITICALITY.get(snap.tags.get("criticality", ""), "medium")
        # En el máximo pero sin presión para escalar más: el techo no está
        # limitando todavía. Se baja un nivel.
        if snap.demand_exceeds_max is False:
            severity = SEVERITY_ORDER[max(SEVERITY_ORDER.index(severity) - 1, 0)]
        # Si todo el cluster está saturado, la alerta de cluster es la que
        # pagina. Las de servicio quedan como contexto.
        if cluster_saturated and severity in ("critical", "high"):
            severity = "medium"
        return severity
    if event == "headroom_low":
        return "low"
    return "info"


def build_message(event: str, snap: ServiceSnapshot, duration_s: int) -> str:
    ratio = f"{snap.desired}/{snap.max_capacity}"
    minutes = duration_s // 60
    if event == "max_reached":
        return f"{snap.service} alcanzó su máximo de tareas ({ratio})."
    if event == "max_sustained":
        text = f"{snap.service} lleva {minutes} min en su máximo de tareas ({ratio})."
        if snap.demand_exceeds_max:
            text += " El auto scaling intentó escalar y el máximo lo bloqueó."
        return text
    if event == "max_recovered":
        return f"{snap.service} volvió por debajo de su máximo ({ratio})."
    if event == "headroom_low":
        return f"{snap.service} usa {snap.utilization_pct:.0f}% de su máximo de tareas ({ratio})."
    return f"{snap.service}: {event}"


def build_event(
    event: str,
    snap: ServiceSnapshot,
    state: ServiceState,
    now: int,
    cfg: Config,
    account_id: str,
    region: str,
    cluster_saturated: bool = False,
) -> dict:
    duration_s = max(now - state.since, 0) if state.status == STATUS_AT_MAX else 0
    console = (
        f"https://{region}.console.aws.amazon.com/ecs/v2/clusters/{snap.cluster}"
        f"/services/{snap.service}/health?region={region}"
    )
    return {
        "event_type": EVENT_PREFIX + event,
        "schema_version": SCHEMA_VERSION,
        "timestamp": iso(now),
        "severity": severity_for(event, snap, cluster_saturated),
        # La herramienta externa agrupa y resuelve por esta clave.
        "dedup_key": f"ecs-capacity:{cfg.environment}:{snap.key}",
        "environment": cfg.environment,
        "account_id": account_id,
        "region": region,
        "cluster": snap.cluster,
        "service": snap.service,
        "owner_team": snap.tags.get("owner", "unknown"),
        "criticality": snap.tags.get("criticality", "unknown"),
        "capacity": {
            "min": snap.min_capacity,
            "max": snap.max_capacity,
            "desired": snap.desired,
            "running": snap.running,
            "pending": snap.pending,
            "utilization_pct": snap.utilization_pct,
        },
        "at_max_since": iso(state.since) if state.status == STATUS_AT_MAX else None,
        "duration_seconds": duration_s,
        "demand_exceeds_max": snap.demand_exceeds_max,
        "cluster_saturated": cluster_saturated,
        "metrics": {"cpu_avg_5m": snap.cpu_avg_5m, "memory_avg_5m": snap.memory_avg_5m},
        "message": build_message(event, snap, duration_s),
        "links": {"runbook": cfg.runbook_url, "dashboard": cfg.dashboard_url, "console": console},
    }


def build_snapshot(snap: ServiceSnapshot, status: str, now: int, cfg: Config) -> dict:
    return {
        "event_type": EVENT_PREFIX + "snapshot",
        "schema_version": SCHEMA_VERSION,
        "timestamp": iso(now),
        "environment": cfg.environment,
        "cluster": snap.cluster,
        "service": snap.service,
        "owner_team": snap.tags.get("owner", "unknown"),
        "criticality": snap.tags.get("criticality", "unknown"),
        "status": status,
        "min": snap.min_capacity,
        "max": snap.max_capacity,
        "desired": snap.desired,
        "running": snap.running,
        "pending": snap.pending,
        "utilization_pct": snap.utilization_pct,
    }


def build_cluster_summary(cluster: str, statuses: dict[str, str], now: int, cfg: Config) -> dict:
    """Una línea por cluster y ejecución, en formato EMF.

    Una sola métrica por cluster (no por servicio) mantiene bajo el costo de
    métricas personalizadas en CloudWatch.
    """
    at_max = sorted(s for s, st in statuses.items() if st == STATUS_AT_MAX)
    warning = sorted(s for s, st in statuses.items() if st == STATUS_WARNING)
    return {
        "event_type": EVENT_PREFIX + "cluster_summary",
        "schema_version": SCHEMA_VERSION,
        "timestamp": iso(now),
        "environment": cfg.environment,
        "Cluster": cluster,
        "ServicesAtMax": len(at_max),
        "ServicesWarning": len(warning),
        "services_total": len(statuses),
        "services_at_max": at_max,
        "cluster_saturated": len(at_max) >= cfg.cluster_saturation_threshold,
        "_aws": {
            "Timestamp": now * 1000,
            "CloudWatchMetrics": [
                {
                    "Namespace": "Deuna/ECSCapacity",
                    "Dimensions": [["Cluster"]],
                    "Metrics": [
                        {"Name": "ServicesAtMax", "Unit": "Count"},
                        {"Name": "ServicesWarning", "Unit": "Count"},
                    ],
                }
            ],
        },
    }


def should_snapshot(status: str, now: int, cfg: Config) -> bool:
    # Servicios con problemas: cada minuto. El resto: cada snapshot_interval.
    if status != STATUS_OK:
        return True
    interval_min = max(cfg.snapshot_interval_seconds // 60, 1)
    return (now // 60) % interval_min == 0


def run(
    snapshots: list[ServiceSnapshot],
    states: dict[str, ServiceState],
    now: int,
    cfg: Config,
    account_id: str = "",
    region: str = "",
) -> tuple[list[dict], dict[str, ServiceState]]:
    """Evalúa todos los servicios. Devuelve las líneas a emitir y los estados nuevos."""
    lines: list[dict] = []
    new_states: dict[str, ServiceState] = {}
    pending_events: list[tuple[str, ServiceSnapshot, ServiceState]] = []
    by_cluster: dict[str, dict[str, str]] = {}

    for snap in snapshots:
        state, events = evaluate(snap, states.get(snap.key), now, cfg)
        new_states[snap.key] = state
        by_cluster.setdefault(snap.cluster, {})[snap.service] = state.status
        pending_events.extend((e, snap, state) for e in events)
        if should_snapshot(state.status, now, cfg):
            lines.append(build_snapshot(snap, state.status, now, cfg))

    saturated: set[str] = set()
    for cluster, statuses in sorted(by_cluster.items()):
        summary = build_cluster_summary(cluster, statuses, now, cfg)
        lines.append(summary)
        if summary["cluster_saturated"]:
            saturated.add(cluster)

    for event, snap, state in pending_events:
        lines.append(
            build_event(event, snap, state, now, cfg, account_id, region, snap.cluster in saturated)
        )
    return lines, new_states


def iso(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- Integración con AWS ---------------------------------------------------


def list_scalable_targets(aas) -> dict[tuple[str, str], tuple[int, int]]:
    """Todos los servicios ECS con auto scaling: nuevos servicios quedan
    cubiertos sin configuración adicional."""
    targets = {}
    for page in aas.get_paginator("describe_scalable_targets").paginate(ServiceNamespace="ecs"):
        for t in page["ScalableTargets"]:
            if t["ScalableDimension"] != "ecs:service:DesiredCount":
                continue
            _, cluster, service = t["ResourceId"].split("/", 2)
            targets[(cluster, service)] = (t["MinCapacity"], t["MaxCapacity"])
    return targets


def describe_services(ecs, targets) -> list[ServiceSnapshot]:
    by_cluster: dict[str, list[str]] = {}
    for cluster, service in targets:
        by_cluster.setdefault(cluster, []).append(service)

    snapshots = []
    for cluster, services in by_cluster.items():
        for i in range(0, len(services), 10):  # límite de la API
            resp = ecs.describe_services(
                cluster=cluster, services=services[i : i + 10], include=["TAGS"]
            )
            for s in resp["services"]:
                if s.get("status") != "ACTIVE":
                    continue
                min_c, max_c = targets[(cluster, s["serviceName"])]
                snapshots.append(
                    ServiceSnapshot(
                        cluster=cluster,
                        service=s["serviceName"],
                        min_capacity=min_c,
                        max_capacity=max_c,
                        desired=s["desiredCount"],
                        running=s["runningCount"],
                        pending=s["pendingCount"],
                        tags={t["key"]: t["value"] for t in s.get("tags", [])},
                    )
                )
    return snapshots


def demand_exceeds_max(aas, snap: ServiceSnapshot, now: int, window_s: int = 600) -> bool:
    """True si el auto scaling quiso escalar y el máximo lo impidió.

    Distingue "en el máximo y necesita más" de "en el máximo pero estable".
    """
    resp = aas.describe_scaling_activities(
        ServiceNamespace="ecs",
        ResourceId=snap.resource_id,
        ScalableDimension="ecs:service:DesiredCount",
        IncludeNotScaledActivities=True,
        MaxResults=20,
    )
    for activity in resp.get("ScalingActivities", []):
        started = activity["StartTime"].timestamp()
        if now - started > window_s:
            continue
        for reason in activity.get("NotScaledReasons", []):
            if reason.get("Code") == "AlreadyAtMaxCapacity":
                return True
    return False


def fetch_utilization(cloudwatch, snaps: list[ServiceSnapshot], now: int) -> dict[str, tuple]:
    """CPU y memoria promedio de los últimos 5 minutos, en una sola llamada."""
    if not snaps:
        return {}
    queries = []
    for i, snap in enumerate(snaps):
        for metric, prefix in (("CPUUtilization", "cpu"), ("MemoryUtilization", "mem")):
            queries.append(
                {
                    "Id": f"{prefix}{i}",
                    "MetricStat": {
                        "Metric": {
                            "Namespace": "AWS/ECS",
                            "MetricName": metric,
                            "Dimensions": [
                                {"Name": "ClusterName", "Value": snap.cluster},
                                {"Name": "ServiceName", "Value": snap.service},
                            ],
                        },
                        "Period": 300,
                        "Stat": "Average",
                    },
                }
            )
    values: dict[str, float] = {}
    for i in range(0, len(queries), 500):  # límite de la API
        resp = cloudwatch.get_metric_data(
            MetricDataQueries=queries[i : i + 500],
            StartTime=datetime.fromtimestamp(now - 600, tz=UTC),
            EndTime=datetime.fromtimestamp(now, tz=UTC),
            ScanBy="TimestampDescending",
        )
        for r in resp["MetricDataResults"]:
            if r["Values"]:
                values[r["Id"]] = round(r["Values"][0], 1)
    return {s.key: (values.get(f"cpu{i}"), values.get(f"mem{i}")) for i, s in enumerate(snaps)}


def load_states(table) -> dict[str, ServiceState]:
    states, kwargs = {}, {}
    while True:
        resp = table.scan(**kwargs)
        for item in resp.get("Items", []):
            states[item["pk"]] = ServiceState(
                status=item["status"],
                since=int(item["since"]),
                alerted_at=int(item.get("alerted_at", 0)),
                below_max_since=int(item.get("below_max_since", 0)),
            )
        if "LastEvaluatedKey" not in resp:
            return states
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def save_states(table, old: dict[str, ServiceState], new: dict[str, ServiceState]) -> None:
    # Escribe solo lo que cambió y borra servicios que ya no existen.
    with table.batch_writer() as batch:
        for key, state in new.items():
            if old.get(key) != state:
                batch.put_item(Item={"pk": key, **asdict(state)})
        for key in old.keys() - new.keys():
            batch.delete_item(Key={"pk": key})


def handler(event, context):  # pragma: no cover - integración con AWS
    import boto3

    cfg = Config.from_env()
    now = int(time.time())
    region = os.environ["AWS_REGION"]
    account_id = context.invoked_function_arn.split(":")[4]

    aas = boto3.client("application-autoscaling")
    ecs = boto3.client("ecs")
    cloudwatch = boto3.client("cloudwatch")
    table = boto3.resource("dynamodb").Table(cfg.state_table)

    snapshots = describe_services(ecs, list_scalable_targets(aas))

    # Contexto adicional solo para los servicios en el máximo: mantiene bajo
    # el número de llamadas a la API.
    at_max = [s for s in snapshots if classify(s, cfg) == STATUS_AT_MAX]
    utilization = fetch_utilization(cloudwatch, at_max, now)
    enriched = {}
    for snap in at_max:
        cpu, mem = utilization.get(snap.key, (None, None))
        try:
            blocked = demand_exceeds_max(aas, snap, now)
        except Exception as exc:  # el contexto es opcional; la detección no
            print(
                json.dumps(
                    {
                        "event_type": EVENT_PREFIX + "monitor_warning",
                        "service": snap.key,
                        "error": str(exc),
                    }
                )
            )
            blocked = None
        enriched[snap.key] = replace(
            snap, demand_exceeds_max=blocked, cpu_avg_5m=cpu, memory_avg_5m=mem
        )
    snapshots = [enriched.get(s.key, s) for s in snapshots]

    old_states = load_states(table)
    lines, new_states = run(snapshots, old_states, now, cfg, account_id, region)
    for line in lines:
        print(json.dumps(line, ensure_ascii=False))
    save_states(table, old_states, new_states)

    return {"services": len(snapshots), "lines": len(lines)}
