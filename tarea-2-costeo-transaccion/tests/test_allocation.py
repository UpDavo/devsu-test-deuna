"""Prueba las vistas SQL con DuckDB sobre un día de datos de ejemplo.

Las vistas usan SQL estándar compatible con Athena (Trino) y DuckDB. Los
valores esperados se calcularon a mano y están explicados en el README.

Ejecutar desde tarea-2-costeo-transaccion:
    pip install duckdb
    python -m unittest discover -s tests
"""

import pathlib
import unittest

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
DAY = "2026-11-01"

CUR_COLUMNS = """
    line_item_usage_start_date TIMESTAMP,
    line_item_product_code VARCHAR,
    line_item_resource_id VARCHAR,
    line_item_line_item_type VARCHAR,
    line_item_unblended_cost DOUBLE,
    savings_plan_savings_plan_effective_cost DOUBLE,
    savings_plan_total_commitment_to_date DOUBLE,
    savings_plan_used_commitment DOUBLE,
    reservation_effective_cost DOUBLE,
    reservation_unused_amortized_upfront_fee_for_billing_period DOUBLE,
    reservation_unused_recurring_fee DOUBLE,
    reservation_reservation_a_r_n VARCHAR
"""

# (hora, producto, recurso, tipo de línea, unblended, costo efectivo de SP)
CUR_ROWS = [
    (
        "00",
        "AmazonApiGateway",
        "arn:aws:apigateway:us-east-1::/restapis/deuna-public-abc",
        "Usage",
        60.0,
        None,
    ),
    (
        "12",
        "AmazonApiGateway",
        "arn:aws:apigateway:us-east-1::/restapis/deuna-public-abc",
        "Usage",
        40.0,
        None,
    ),
    # Lambda cubierta por Savings Plan: unblended 57.14, costo amortizado 40.
    (
        "00",
        "AWSLambda",
        "arn:aws:lambda:us-east-1:333333333333:function:transfer-validator",
        "SavingsPlanCoveredUsage",
        57.14,
        40.0,
    ),
    (
        "00",
        "AWSLambda",
        "arn:aws:lambda:us-east-1:333333333333:function:transfer-validator",
        "SavingsPlanNegation",
        -57.14,
        None,
    ),
    (
        "00",
        "AWSLambda",
        "arn:aws:lambda:us-east-1:333333333333:function:profile-updater",
        "Usage",
        10.0,
        None,
    ),
    # Aurora: instancias y almacenamiento, recursos distintos del mismo cluster.
    (
        "00",
        "AmazonRDS",
        "arn:aws:rds:us-east-1:333333333333:db:deuna-production-aurora-1",
        "Usage",
        250.0,
        None,
    ),
    (
        "00",
        "AmazonRDS",
        "arn:aws:rds:us-east-1:333333333333:cluster:deuna-production-aurora",
        "Usage",
        50.0,
        None,
    ),
    (
        "00",
        "AWSQueueService",
        "arn:aws:sqs:us-east-1:333333333333:ledger-events",
        "Usage",
        20.0,
        None,
    ),
    ("00", "AmazonS3", "deuna-production-data-333333333333-us-east-1", "Usage", 10.0, None),
    (
        "00",
        "AmazonEC2",
        "arn:aws:ec2:us-east-1:333333333333:natgateway/nat-0abc",
        "Usage",
        45.0,
        None,
    ),
    ("00", "awskms", "arn:aws:kms:us-east-1:333333333333:key/1234", "Usage", 5.0, None),
    # CloudWatch no está en el catálogo: queda como 'unmapped' y va a overhead.
    ("00", "AmazonCloudWatch", "", "Usage", 20.0, None),
    # Impuestos: excluidos.
    ("00", "AmazonRDS", "", "Tax", 30.0, None),
]

# (componente, tipo, unidades). Los totales se pueden cargar en pocas filas:
# la vista suma unidades.
USAGE_ROWS = [
    ("apigw-public", "monetary", 600_000),
    ("apigw-public", "non_monetary", 1_400_000),
    ("aurora-core", "monetary", 7_200_000),
    ("aurora-core", "non_monetary", 4_800_000),
    ("sqs-ledger", "monetary", 900_000),
    ("sqs-ledger", "non_monetary", 100_000),
    ("s3-receipts", "monetary", 80e9),
    ("s3-receipts", "non_monetary", 20e9),
    # Transacciones sin tipo: se ignoran.
    ("apigw-public", "unknown", 999_999),
]

COUNTS = [("monetary", 300_000), ("non_monetary", 1_400_000)]


def build(cur_rows=CUR_ROWS, usage_rows=USAGE_ROWS):
    db = duckdb.connect()
    db.execute(f"CREATE TABLE cur ({CUR_COLUMNS})")
    for hour, product, resource, kind, unblended, sp_cost in cur_rows:
        db.execute(
            "INSERT INTO cur VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, '')",
            [f"{DAY} {hour}:00:00", product, resource, kind, unblended, sp_cost],
        )
    db.execute(
        "CREATE TABLE component_catalog AS "
        "SELECT * FROM read_csv(?, header = true, all_varchar = true)",
        [str(ROOT / "catalog" / "component_catalog.csv")],
    )
    db.execute("ALTER TABLE component_catalog ALTER priority TYPE INTEGER")
    db.execute("UPDATE component_catalog SET driver = NULL WHERE driver = ''")
    db.execute(
        "CREATE TABLE cost_events (event_time TIMESTAMP, transaction_id VARCHAR, "
        "transaction_type VARCHAR, component VARCHAR, units DOUBLE)"
    )
    for i, (component, ttype, units) in enumerate(usage_rows):
        db.execute(
            "INSERT INTO cost_events VALUES (?, ?, ?, ?, ?)",
            [f"{DAY} 10:00:00", f"tx-{i}", ttype, component, units],
        )
    db.execute(
        "CREATE TABLE transaction_counts "
        "(usage_date DATE, transaction_type VARCHAR, transactions BIGINT)"
    )
    for ttype, n in COUNTS:
        db.execute("INSERT INTO transaction_counts VALUES (?, ?, ?)", [DAY, ttype, n])
    for sql in sorted((ROOT / "sql").glob("*.sql")):
        db.execute(sql.read_text())
    return db


def rows(db, query):
    cur = db.execute(query)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r, strict=True)) for r in cur.fetchall()]


class CostPerTransactionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = build()
        cls.result = {
            r["transaction_type"]: r for r in rows(cls.db, "SELECT * FROM v_cost_per_transaction")
        }

    def test_amortized_cost_excludes_tax_and_uses_savings_plan_rate(self):
        total = self.db.execute("SELECT SUM(cost) FROM v_cur_daily_cost").fetchone()[0]
        self.assertAlmostEqual(total, 550.0, places=6)

    def test_aurora_instance_and_cluster_lines_map_to_one_component(self):
        cost = self.db.execute(
            "SELECT SUM(cost) FROM v_component_cost WHERE component = 'aurora-core'"
        ).fetchone()[0]
        self.assertAlmostEqual(cost, 300.0, places=6)

    def test_direct_costs(self):
        self.assertAlmostEqual(self.result["monetary"]["direct_cost"], 40.0, places=6)
        self.assertAlmostEqual(self.result["non_monetary"]["direct_cost"], 10.0, places=6)

    def test_usage_based_costs(self):
        # API 30/70, Aurora 60/40, SQS 90/10, S3 80/20
        self.assertAlmostEqual(self.result["monetary"]["usage_cost"], 30 + 180 + 18 + 8, places=6)
        self.assertAlmostEqual(
            self.result["non_monetary"]["usage_cost"], 70 + 120 + 2 + 2, places=6
        )

    def test_overhead_split_proportional_to_attributed_cost(self):
        # Overhead = NAT 45 + KMS 5 + CloudWatch 20 = 70; reparto 276/480 y 204/480
        self.assertAlmostEqual(self.result["monetary"]["overhead_cost"], 40.25, places=6)
        self.assertAlmostEqual(self.result["non_monetary"]["overhead_cost"], 29.75, places=6)

    def test_cost_per_transaction(self):
        self.assertAlmostEqual(self.result["monetary"]["total_cost"], 316.25, places=6)
        self.assertAlmostEqual(self.result["monetary"]["cost_per_1000"], 1.0541667, places=6)
        self.assertAlmostEqual(self.result["non_monetary"]["total_cost"], 233.75, places=6)
        self.assertAlmostEqual(self.result["non_monetary"]["cost_per_1000"], 0.1669643, places=6)

    def test_reconciliation_passes(self):
        r = rows(self.db, "SELECT * FROM v_reconciliation")[0]
        self.assertAlmostEqual(r["allocation_gap_pct"], 0.0, places=6)
        self.assertAlmostEqual(r["unmapped_pct"], 20 / 550 * 100, places=6)
        self.assertTrue(r["passed"])


class MissingTelemetryTest(unittest.TestCase):
    def test_shared_component_without_usage_falls_back_to_overhead(self):
        # Sin telemetría de Aurora ese día: su costo no se pierde, pasa a overhead.
        db = build(usage_rows=[r for r in USAGE_ROWS if r[0] != "aurora-core"])
        r = rows(db, "SELECT * FROM v_reconciliation")[0]
        self.assertAlmostEqual(r["allocation_gap_pct"], 0.0, places=6)
        self.assertAlmostEqual(r["overhead_pct"], 370 / 550 * 100, places=6)
        self.assertFalse(r["passed"])  # overhead > 20 %: el pipeline no publica


if __name__ == "__main__":
    unittest.main()
