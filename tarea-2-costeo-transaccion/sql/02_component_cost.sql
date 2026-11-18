-- Asigna cada línea de costo a un componente del catálogo.
--
-- component_catalog se genera cada día desde los tags de los recursos
-- (cost:component, cost:flow, cost:driver) más entradas manuales para lo que
-- no admite tags. Si una línea coincide con varios patrones gana la de mayor
-- prioridad (la más específica). Lo que no coincide con nada queda como
-- 'unmapped' y se reparte como overhead; su porcentaje es un indicador de
-- calidad de la conciliación.

CREATE OR REPLACE VIEW v_component_cost AS
WITH matched AS (
    SELECT
        c.usage_date,
        c.product_code,
        c.resource_id,
        c.cost,
        k.component,
        k.flow,
        k.driver,
        ROW_NUMBER() OVER (
            PARTITION BY c.usage_date, c.product_code, c.resource_id
            ORDER BY k.priority DESC
        ) AS rn
    FROM v_cur_daily_cost c
    LEFT JOIN component_catalog k
        ON c.resource_id LIKE k.resource_pattern
       AND (k.product_code IS NULL OR k.product_code = c.product_code)
)
SELECT
    usage_date,
    COALESCE(component, 'unmapped') AS component,
    COALESCE(flow, 'shared')        AS flow,   -- monetary | non_monetary | shared
    driver,                                    -- unidad de uso; NULL = overhead
    SUM(cost)                       AS cost
FROM matched
WHERE rn = 1
GROUP BY 1, 2, 3, 4;
