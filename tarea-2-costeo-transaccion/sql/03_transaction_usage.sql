-- Uso de cada componente por tipo de transacción, desde la telemetría.
--
-- cost_events es la tabla Glue sobre los logs estructurados que los
-- servicios ya emiten (CloudWatch Logs -> Firehose -> S3 en Parquet).
-- Cada línea lleva transaction_id, transaction_type, component y las
-- unidades consumidas en la unidad del driver del componente:
--
--   apigw-*    requests      1 por llamada
--   lambda-*   gb_seconds    duración facturada × memoria / 1024
--   aurora-*   db_time_ms    tiempo de las consultas medido por el cliente
--   sqs-*      requests      mensajes, en bloques de 64 KB
--   s3-*       bytes         bytes escritos y leídos
--   ecs-*      cpu_ms        tiempo de CPU de la petición
--
-- Solo importan las proporciones entre tipos, no los totales absolutos: un
-- muestreo uniforme de la telemetría da el mismo resultado a menor costo.

CREATE OR REPLACE VIEW v_transaction_usage AS
SELECT
    CAST(date_trunc('day', event_time) AS DATE) AS usage_date,
    component,
    transaction_type,
    SUM(units) AS units
FROM cost_events
WHERE transaction_type IN ('monetary', 'non_monetary')
GROUP BY 1, 2, 3;
