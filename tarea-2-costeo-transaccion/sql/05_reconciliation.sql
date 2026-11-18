-- Controles de calidad. El dashboard no muestra un día que no pase los tres.
--
--   allocation_gap_pct   diferencia entre lo atribuido y CUR. Debe ser ~0.
--   unmapped_pct         costo sin componente en el catálogo. Umbral: 5 %.
--   overhead_pct         costo repartido sin driver. Umbral: 20 %. Si sube,
--                        hay que medir algún componente que hoy no se mide.

CREATE OR REPLACE VIEW v_reconciliation AS
WITH cur_total AS (
    SELECT usage_date, SUM(cost) AS cur_cost
    FROM v_cur_daily_cost
    GROUP BY 1
),

allocated AS (
    SELECT usage_date, SUM(total_cost) AS allocated_cost, SUM(overhead_cost) AS overhead_cost
    FROM v_cost_per_transaction
    GROUP BY 1
),

unmapped AS (
    SELECT usage_date, SUM(cost) AS unmapped_cost
    FROM v_component_cost
    WHERE component = 'unmapped'
    GROUP BY 1
)

SELECT
    c.usage_date,
    c.cur_cost,
    a.allocated_cost,
    100 * ABS(c.cur_cost - COALESCE(a.allocated_cost, 0)) / NULLIF(c.cur_cost, 0) AS allocation_gap_pct,
    100 * COALESCE(u.unmapped_cost, 0) / NULLIF(c.cur_cost, 0)                   AS unmapped_pct,
    100 * COALESCE(a.overhead_cost, 0) / NULLIF(c.cur_cost, 0)                   AS overhead_pct,
    (
        100 * ABS(c.cur_cost - COALESCE(a.allocated_cost, 0)) / NULLIF(c.cur_cost, 0) < 0.5
        AND 100 * COALESCE(u.unmapped_cost, 0) / NULLIF(c.cur_cost, 0) < 5
        AND 100 * COALESCE(a.overhead_cost, 0) / NULLIF(c.cur_cost, 0) < 20
    ) AS passed
FROM cur_total c
LEFT JOIN allocated a ON a.usage_date = c.usage_date
LEFT JOIN unmapped  u ON u.usage_date = c.usage_date;
