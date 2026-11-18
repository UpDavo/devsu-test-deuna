-- Costo diario amortizado por recurso, desde CUR 2.0 (AWS Data Exports).
--
-- "Amortizado" reparte Savings Plans y Reserved Instances sobre el uso que
-- cubren. Sin esto, el costo por transacción saltaría el mes de la compra y
-- caería a casi cero el resto del año.
--
-- Impuestos, créditos y reembolsos se excluyen: se tratan a nivel de factura,
-- no de costo unitario.

CREATE OR REPLACE VIEW v_cur_daily_cost AS
SELECT
    CAST(date_trunc('day', line_item_usage_start_date) AS DATE) AS usage_date,
    line_item_product_code                                      AS product_code,
    COALESCE(line_item_resource_id, '')                         AS resource_id,
    SUM(
        CASE
            WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
                THEN savings_plan_savings_plan_effective_cost
            -- Compromiso no usado: costo real, sin recurso. Termina como overhead.
            WHEN line_item_line_item_type = 'SavingsPlanRecurringFee'
                THEN savings_plan_total_commitment_to_date - savings_plan_used_commitment
            WHEN line_item_line_item_type IN ('SavingsPlanNegation', 'SavingsPlanUpfrontFee')
                THEN 0
            WHEN line_item_line_item_type = 'DiscountedUsage'
                THEN reservation_effective_cost
            WHEN line_item_line_item_type = 'RIFee'
                THEN reservation_unused_amortized_upfront_fee_for_billing_period
                   + reservation_unused_recurring_fee
            WHEN line_item_line_item_type = 'Fee' AND COALESCE(reservation_reservation_a_r_n, '') <> ''
                THEN 0
            ELSE line_item_unblended_cost
        END
    ) AS cost
FROM cur
WHERE line_item_line_item_type NOT IN ('Tax', 'Credit', 'Refund')
GROUP BY 1, 2, 3;
