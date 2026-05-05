-- ============================================================
-- PUNTO 1. CONCEPTOS FUNDAMENTALES
-- Snowflake & costos
-- ============================================================
-- Query corregido
-- ------------------------------------------------------------
SELECT
    i.inspection_id,
    i.client_id,
    c.company_name,
    c.plan,
    i.status,
    i.scheduled_at,
    i.started_at,
    i.completed_at
FROM marts.fct_inspections i
JOIN marts.dim_clients c
    ON i.client_id = c.client_id
WHERE i.completed_at >= '2024-01-01'::timestamp
  AND i.completed_at < '2025-01-01'::timestamp;

-- ============================================================
-- PUNTO 2. SQL & Modelado en Snowflake
-- Snowflake & costos
-- ============================================================
-- Métricas operacionales por cliente, mes e inspection_type para 2024
-- ------------------------------------------------------------

WITH inspections_completed_2024 AS (
    SELECT
        i.inspection_id,
        i.client_id,
        i.status,
        i.started_at,
        i.completed_at,
        i.metadata:inspection_type::string AS inspection_type
    FROM raw.inspections i
    WHERE i.status = 'completed'
      AND i.completed_at >= '2024-01-01'::timestamp
      AND i.completed_at <  '2025-01-01'::timestamp
      AND i.started_at IS NOT NULL
      AND i.completed_at IS NOT NULL
      AND i.completed_at >= i.started_at
)

SELECT
    c.client_id,
    c.company_name,
    DATE_TRUNC('month', i.completed_at)::date AS inspection_month,
    COALESCE(i.inspection_type, 'unknown') AS inspection_type,
    COUNT(*) AS total_completed_inspections,
    AVG(DATEDIFF('minute', i.started_at, i.completed_at)) AS avg_duration_minutes
FROM inspections_completed_2024 i
JOIN raw.clients c
    ON i.client_id = c.client_id
GROUP BY
    c.client_id,
    c.company_name,
    DATE_TRUNC('month', i.completed_at)::date,
    COALESCE(i.inspection_type, 'unknown')
ORDER BY
    inspection_month,
    c.company_name,
    inspection_type;


-- ------------------------------------------------------------
-- Ejemplo de modelo dbt incremental para inspecciones
-- ------------------------------------------------------------
-- En un proyecto dbt, la configuración iría dentro del archivo .sql
-- del modelo. Se deja comentada para mantener este archivo como SQL ejecutable.

-- {{
--   config(
--     materialized='incremental',
--     unique_key='inspection_id',
--     incremental_strategy='merge'
--   )
-- }}

-- Decisión:
-- Modelo incremental recomendado porque inspections puede crecer
-- constantemente y tiene llave única inspection_id.
-- ------------------------------------------------------------

SELECT
    inspection_id,
    client_id,
    inspector_id,
    status,
    scheduled_at,
    started_at,
    completed_at,
    metadata
FROM raw.inspections;

-- Bloque incremental dbt de referencia:
-- {% if is_incremental() %}
-- WHERE completed_at >= (
--     SELECT COALESCE(MAX(completed_at), '1900-01-01')
--     FROM {{ this }}
-- )
-- {% endif %}

-- ------------------------------------------------------------
-- Top 3 clientes con mayor porcentaje de inspecciones fallidas en 2024
-- ------------------------------------------------------------

WITH inspections_2024 AS (
    SELECT
        i.inspection_id,
        i.client_id,
        i.status
    FROM raw.inspections i
    WHERE i.scheduled_at >= '2024-01-01'::timestamp
      AND i.scheduled_at <  '2025-01-01'::timestamp
),

client_failure_rate AS (
    SELECT
        c.client_id,
        c.company_name,
        COUNT(*) AS total_inspections,
        COUNT_IF(i.status = 'failed') AS failed_inspections,
        ROUND(
            COUNT_IF(i.status = 'failed') * 100.0 / NULLIF(COUNT(*), 0),
            2
        ) AS failed_percentage
    FROM inspections_2024 i
    JOIN raw.clients c
        ON i.client_id = c.client_id
    GROUP BY
        c.client_id,
        c.company_name
)

SELECT
    client_id,
    company_name,
    total_inspections,
    failed_inspections,
    failed_percentage
FROM client_failure_rate
ORDER BY
    failed_percentage DESC,
    failed_inspections DESC
LIMIT 3;

-- ============================================================
-- PUNTO 3. CASO REAL - INTEGRACIÓN SODAS SAS
-- ============================================================
-- 5. Tabla de auditoría para manifiesto de archivos SODAS
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS audit.sodas_file_manifest (
    batch_id STRING,
    dataset_name STRING,
    source_file STRING,
    file_date DATE,
    file_version STRING,
    expected_rows NUMBER,
    loaded_rows NUMBER,
    rejected_rows NUMBER,
    file_checksum STRING,
    load_status STRING,
    received_at TIMESTAMP,
    loaded_at TIMESTAMP,
    error_message STRING
);

-- ------------------------------------------------------------
-- 5 Tabla RAW landing para auxilios viales
-- ------------------------------------------------------------
-- Decisión:
-- Se agregan columnas técnicas para trazabilidad:
-- batch_id, source_file, source_row_number, row_hash e ingested_at.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.sodas_road_assistance_landing (
    auxilio_id VARCHAR,
    placa VARCHAR,
    tipo_vehiculo VARCHAR,
    cedi VARCHAR,
    fecha_auxilio DATE,
    motivo VARCHAR,
    tiempo_atencion NUMBER,
    estado VARCHAR,
    batch_id VARCHAR,
    source_file VARCHAR,
    source_row_number NUMBER,
    row_hash VARCHAR,
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);


-- ------------------------------------------------------------
-- 5 Tabla RAW landing para alquileres de camiones
-- ------------------------------------------------------------
-- Misma lógica de trazabilidad que auxilios viales.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.sodas_rentals_landing (
    alquiler_id VARCHAR,
    cedi VARCHAR,
    tipo_vehiculo VARCHAR,
    motivo_alquiler VARCHAR,
    fecha_inicio DATE,
    fecha_fin DATE,
    costo NUMBER(18,2),
    proveedor VARCHAR,
    batch_id VARCHAR,
    source_file VARCHAR,
    source_row_number NUMBER,
    row_hash VARCHAR,
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);


-- ------------------------------------------------------------
-- 7. Tabla de expectativas de envío
-- ------------------------------------------------------------
-- Detectar si SODAS no envió un archivo esperado.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS audit.sodas_expected_submissions (
    dataset_name STRING,
    expected_date DATE,
    expected_due_timestamp TIMESTAMP,
    expected_min_rows NUMBER,
    is_required BOOLEAN
);


-- ------------------------------------------------------------
-- 7 Alerta lógica: archivos esperados no recibidos
-- ------------------------------------------------------------
-- Si la fecha u hora esperada ya pasó y no hay carga exitosa,
-- se debe generar alerta al equipo responsable.
-- ------------------------------------------------------------

SELECT
    e.dataset_name,
    e.expected_date,
    e.expected_due_timestamp,
    e.expected_min_rows
FROM audit.sodas_expected_submissions e
LEFT JOIN audit.sodas_file_manifest m
    ON e.dataset_name = m.dataset_name
   AND e.expected_date = m.file_date
   AND m.load_status = 'SUCCESS'
WHERE e.is_required = TRUE
  AND CURRENT_TIMESTAMP() > e.expected_due_timestamp
  AND m.batch_id IS NULL;


-- ------------------------------------------------------------
-- 7. Validación: auxilios duplicados por auxilio_id
-- ------------------------------------------------------------
-- auxilio_id se considera llave única de negocio.
-- ------------------------------------------------------------

SELECT
    auxilio_id,
    COUNT(*) AS total_records
FROM raw.sodas_road_assistance_landing
WHERE auxilio_id IS NOT NULL
GROUP BY auxilio_id
HAVING COUNT(*) > 1
ORDER BY total_records DESC;


-- ------------------------------------------------------------
-- 7. Validación: alquileres duplicados por alquiler_id
-- ------------------------------------------------------------
-- alquiler_id se considera llave única de negocio.
-- ------------------------------------------------------------

SELECT
    alquiler_id,
    COUNT(*) AS total_records
FROM raw.sodas_rentals_landing
WHERE alquiler_id IS NOT NULL
GROUP BY alquiler_id
HAVING COUNT(*) > 1
ORDER BY total_records DESC;


-- ------------------------------------------------------------
-- 7. Validación: CEDI de auxilios no existe en geo_distribution
-- ------------------------------------------------------------
-- No se eliminan registros sin geografía; se reportan como problema
-- de calidad para corregir maestro o archivo enviado.
-- ------------------------------------------------------------

SELECT
    a.cedi,
    COUNT(*) AS total_records
FROM raw.sodas_road_assistance_landing a
LEFT JOIN raw.geo_distribution g
    ON UPPER(TRIM(a.cedi)) = UPPER(TRIM(g.cedi))
WHERE g.cedi IS NULL
GROUP BY a.cedi
ORDER BY total_records DESC;


-- ------------------------------------------------------------
-- 7. Validación: CEDI de alquileres no existe en geo_distribution
-- ------------------------------------------------------------

SELECT
    r.cedi,
    COUNT(*) AS total_records
FROM raw.sodas_rentals_landing r
LEFT JOIN raw.geo_distribution g
    ON UPPER(TRIM(r.cedi)) = UPPER(TRIM(g.cedi))
WHERE g.cedi IS NULL
GROUP BY r.cedi
ORDER BY total_records DESC;


-- ============================================================
-- PUNTO 4. QUERIES DEL DASHBOARD EN METABASE
-- ============================================================
-- 4.1 Dashboard Alquileres:
-- Cantidad total de alquileres por mes y territorio
-- Se usa fecha_inicio como fecha operativa del alquiler.
-- Se agrupa por mes y territorio.
-- ------------------------------------------------------------

SELECT
    DATE_TRUNC('month', fecha_inicio)::date AS rental_month,
    COALESCE(territory, 'Sin territorio') AS territory,
    COUNT(*) AS total_rentals
FROM marts.fct_sodas_rentals
WHERE fecha_inicio IS NOT NULL
GROUP BY
    DATE_TRUNC('month', fecha_inicio)::date,
    COALESCE(territory, 'Sin territorio')
ORDER BY
    rental_month,
    territory;


-- ------------------------------------------------------------
-- 4.2 Dashboard Alquileres:
-- Costo acumulado mes a mes con variación respecto al mes anterior
-- Calcula costo mensual, acumulado y variación mensual.
-- La consulta está a nivel general. Si se requiere por territorio,
-- se agrega territory al GROUP BY y al PARTITION BY.
-- ------------------------------------------------------------

WITH monthly_cost AS (
    SELECT
        DATE_TRUNC('month', fecha_inicio)::date AS rental_month,
        SUM(costo) AS monthly_cost_cop
    FROM marts.fct_sodas_rentals
    WHERE fecha_inicio IS NOT NULL
    GROUP BY
        DATE_TRUNC('month', fecha_inicio)::date
)

SELECT
    rental_month,
    monthly_cost_cop,
    SUM(monthly_cost_cop) OVER (
        ORDER BY rental_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS accumulated_cost_cop,
    monthly_cost_cop
        - LAG(monthly_cost_cop) OVER (ORDER BY rental_month) AS variation_vs_previous_month_cop,
    ROUND(
        (
            monthly_cost_cop
            - LAG(monthly_cost_cop) OVER (ORDER BY rental_month)
        ) * 100.0
        / NULLIF(LAG(monthly_cost_cop) OVER (ORDER BY rental_month), 0),
        2
    ) AS variation_vs_previous_month_pct
FROM monthly_cost
ORDER BY rental_month;


-- ------------------------------------------------------------
-- 4.3 Dashboard Alquileres:
-- Motivos de alquiler de camiones en orden descendente
-- Agrupa por motivo de alquiler y ordena de mayor a menor frecuencia.
-- Los nulos se muestran como 'Sin motivo informado'.
-- ------------------------------------------------------------

SELECT
    COALESCE(motivo_alquiler, 'Sin motivo informado') AS rental_reason,
    COUNT(*) AS total_rentals
FROM marts.fct_sodas_rentals
GROUP BY
    COALESCE(motivo_alquiler, 'Sin motivo informado')
ORDER BY
    total_rentals DESC,
    rental_reason;


-- ------------------------------------------------------------
-- 4.4 Dashboard Alquileres:
-- Tipos de vehículos alquilados
-- Permite conocer la demanda por tipo de vehículo.
-- ------------------------------------------------------------

SELECT
    COALESCE(tipo_vehiculo, 'Sin tipo informado') AS vehicle_type,
    COUNT(*) AS total_rentals
FROM marts.fct_sodas_rentals
GROUP BY
    COALESCE(tipo_vehiculo, 'Sin tipo informado')
ORDER BY
    total_rentals DESC,
    vehicle_type;


-- ------------------------------------------------------------
-- 4.5 Dashboard Índice de Auxilios Viales:
-- Cantidad neta de auxilios viales por mes y CEDI
-- "Cantidad neta" significa auxilios efectivos, excluyendo cancelados.
-- ------------------------------------------------------------

SELECT
    DATE_TRUNC('month', fecha_auxilio)::date AS assistance_month,
    cedi,
    COALESCE(territory, 'Sin territorio') AS territory,
    COALESCE(logistic_operator, 'Sin operador') AS logistic_operator,
    COUNT_IF(estado <> 'cancelado') AS net_road_assistance_count,
    COUNT_IF(estado = 'cancelado') AS cancelled_count,
    COUNT(*) AS total_records
FROM marts.fct_sodas_road_assistance
WHERE fecha_auxilio IS NOT NULL
GROUP BY
    DATE_TRUNC('month', fecha_auxilio)::date,
    cedi,
    COALESCE(territory, 'Sin territorio'),
    COALESCE(logistic_operator, 'Sin operador')
ORDER BY
    assistance_month,
    cedi;


-- ------------------------------------------------------------
-- 4.6 Dashboard Índice de Auxilios Viales:
-- Top placas con mayor número de auxilios
-- Se excluyen placas nulas y registros cancelados para medir eventos
-- operativos efectivos.
-- ------------------------------------------------------------

SELECT
    placa,
    COUNT(*) AS total_road_assistance,
    AVG(tiempo_atencion) AS avg_resolution_minutes,
    COUNT_IF(estado = 'resuelto') AS resolved_count,
    COUNT_IF(estado = 'en_proceso') AS in_progress_count
FROM marts.fct_sodas_road_assistance
WHERE placa IS NOT NULL
  AND estado <> 'cancelado'
GROUP BY
    placa
ORDER BY
    total_road_assistance DESC,
    avg_resolution_minutes DESC
LIMIT 10;


-- ------------------------------------------------------------
-- 4.7 Dashboard Índice de Auxilios Viales:
-- Tiempo promedio de atención por mes, CEDI y territorio
-- Aunque no fue solicitada explícitamente, es útil para medir eficiencia
-- operativa de los auxilios viales.
-- ------------------------------------------------------------

SELECT
    DATE_TRUNC('month', fecha_auxilio)::date AS assistance_month,
    cedi,
    COALESCE(territory, 'Sin territorio') AS territory,
    AVG(tiempo_atencion) AS avg_attention_minutes,
    COUNT(*) AS total_assistance
FROM marts.fct_sodas_road_assistance
WHERE fecha_auxilio IS NOT NULL
  AND estado = 'resuelto'
GROUP BY
    DATE_TRUNC('month', fecha_auxilio)::date,
    cedi,
    COALESCE(territory, 'Sin territorio')
ORDER BY
    assistance_month,
    cedi;
