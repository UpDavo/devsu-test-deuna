-- Costo por transacción, por día y tipo.
--
-- Tres capas de atribución, de la más precisa a la menos:
--   1. Directo:   componentes dedicados a un flujo (flow = monetary | non_monetary).
--   2. Por uso:   componentes compartidos con driver medible. Se reparten según
--                 la proporción de unidades consumidas por cada tipo ese día.
--   3. Overhead:  compartidos sin driver (NAT, KMS, CloudWatch, compromisos no
--                 usados, 'unmapped') o con driver sin telemetría ese día. Se
--                 reparten en proporción al costo ya atribuido en 1 y 2.
--
-- transaction_counts viene del ledger transaccional (la misma fuente que usa
-- finanzas), no de los logs: el denominador debe ser exacto.
--
-- Invariante: la suma de total_cost de un día es igual al costo de CUR de
-- ese día. 05_reconciliation.sql lo verifica.

CREATE OR REPLACE VIEW v_cost_per_transaction AS
WITH usage_share AS (
    SELECT
        usage_date,
        component,
        transaction_type,
        units / SUM(units) OVER (PARTITION BY usage_date, component) AS share
    FROM v_transaction_usage
    WHERE units > 0
),

measured AS (
    SELECT DISTINCT usage_date, component FROM usage_share
),

classified AS (
    SELECT
        c.usage_date,
        c.component,
        c.flow,
        c.cost,
        CASE
            WHEN c.flow IN ('monetary', 'non_monetary')             THEN 'direct'
            WHEN c.driver IS NOT NULL AND m.component IS NOT NULL   THEN 'usage'
            ELSE 'overhead'
        END AS layer
    FROM v_component_cost c
    LEFT JOIN measured m
        ON m.usage_date = c.usage_date AND m.component = c.component
),

attributed AS (
    SELECT usage_date, flow AS transaction_type, 'direct' AS layer, cost
    FROM classified
    WHERE layer = 'direct'

    UNION ALL

    SELECT c.usage_date, s.transaction_type, 'usage' AS layer, c.cost * s.share AS cost
    FROM classified c
    JOIN usage_share s
        ON s.usage_date = c.usage_date AND s.component = c.component
    WHERE c.layer = 'usage'
),

by_type AS (
    SELECT
        usage_date,
        transaction_type,
        SUM(CASE WHEN layer = 'direct' THEN cost ELSE 0 END) AS direct_cost,
        SUM(CASE WHEN layer = 'usage'  THEN cost ELSE 0 END) AS usage_cost,
        SUM(cost)                                            AS attributed_cost
    FROM attributed
    GROUP BY 1, 2
),

overhead AS (
    SELECT usage_date, SUM(cost) AS overhead_pool
    FROM classified
    WHERE layer = 'overhead'
    GROUP BY 1
),

loaded AS (
    SELECT
        b.usage_date,
        b.transaction_type,
        b.direct_cost,
        b.usage_cost,
        COALESCE(o.overhead_pool, 0)
            * b.attributed_cost / SUM(b.attributed_cost) OVER (PARTITION BY b.usage_date) AS overhead_cost
    FROM by_type b
    LEFT JOIN overhead o ON o.usage_date = b.usage_date
)

SELECT
    l.usage_date,
    l.transaction_type,
    l.direct_cost,
    l.usage_cost,
    l.overhead_cost,
    l.direct_cost + l.usage_cost + l.overhead_cost                                   AS total_cost,
    t.transactions,
    (l.direct_cost + l.usage_cost + l.overhead_cost) / NULLIF(t.transactions, 0)        AS cost_per_transaction,
    1000 * (l.direct_cost + l.usage_cost + l.overhead_cost) / NULLIF(t.transactions, 0) AS cost_per_1000
FROM loaded l
LEFT JOIN transaction_counts t
    ON t.usage_date = l.usage_date AND t.transaction_type = l.transaction_type;
