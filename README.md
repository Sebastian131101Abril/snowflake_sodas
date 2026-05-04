# Prueba Técnica - Snowflake / dbt / Metabase / SODAS SAS

## 1. Arquitectura propuesta

Flujo general:

Cloud SQL PostgreSQL → Fivetran → Snowflake → dbt → Metabase

Se propone separar los datos en capas:

- RAW: datos crudos provenientes de Fivetran o archivos externos.
- STAGING: limpieza, tipado, normalización y deduplicación básica.
- INTERMEDIATE: reglas de negocio y joins reutilizables.
- MARTS: tablas finales optimizadas para consumo en Metabase.
- AUDIT: control de cargas, manifiestos, errores y alertas.

## 2. Convenciones de nomenclatura

Se utiliza `snake_case` y prefijos según la capa:

- `stg_`: modelos staging.
- `int_`: modelos intermedios.
- `dim_`: dimensiones.
- `fct_`: tablas de hechos.
- `agg_`: tablas agregadas.
- `mart_`: modelos finales de negocio.

## 3. Criterios de materialización dbt

### View

Se usa para modelos livianos de limpieza inicial, como `stg_clients` o `stg_geo_distribution`.

### Table

Se usa para modelos con joins, agregaciones o consumo frecuente desde Metabase.

### Incremental

Se usa para tablas grandes que crecen en el tiempo y tienen llave única, como `inspection_id`, `auxilio_id` o `alquiler_id`.

## 4. Decisiones de performance y costo en Snowflake

Para reducir costos y mejorar rendimiento:

- Evitar `SELECT *`.
- Consultar solo columnas necesarias.
- Filtrar por rangos de fechas.
- Evitar `ORDER BY` innecesarios.
- Usar tablas agregadas para dashboards.
- Revisar Query Profile antes de escalar warehouses.
- Evaluar clustering keys solo en tablas grandes con filtros frecuentes.
- Separar warehouses de ETL y BI.
- Aprovechar result cache cuando aplique.

## 5. Integración SODAS SAS

Se recomienda que SODAS cargue archivos CSV en una carpeta cloud controlada o stage externo.

El flujo propuesto es:

1. SODAS descarga una plantilla oficial.
2. SODAS diligencia los archivos de auxilios y alquileres.
3. SODAS sube los archivos a una carpeta controlada.
4. Snowflake carga los archivos a tablas RAW landing.
5. Se registra la carga en tablas de auditoría.
6. dbt limpia, tipa y deduplica la información.
7. dbt cruza la data con `geo_distribution`.
8. dbt construye tablas finales en MARTS.
9. Metabase consume únicamente tablas finales o agregadas.

## 6. Control de calidad

Se implementan validaciones para:

- Archivos esperados no recibidos.
- Archivos con cero filas.
- IDs duplicados.
- CEDI inexistente en `geo_distribution`.
- Estados inválidos.
- Costos negativos.
- Fechas inconsistentes.
- Tiempos de atención negativos.

## 7. Supuestos

- `auxilio_id` identifica de forma única un auxilio vial.
- `alquiler_id` identifica de forma única un alquiler.
- `cedi` es la llave para cruzar con `geo_distribution`.
- Para inspecciones completadas se usa `completed_at`.
- Para inspecciones fallidas se usa `scheduled_at`.
- Para alquileres se usa `fecha_inicio`.
- Para auxilios viales se usa `fecha_auxilio`.
- “Cantidad neta de auxilios” significa auxilios no cancelados.
- Los costos están en COP.

## 8. Ambigüedades detectadas

- No se especifica la frecuencia esperada de envío de archivos por parte de SODAS.
- No se indica si los archivos pueden traer correcciones históricas.
- No se aclara si `geo_distribution` debe manejar histórico tipo SCD.
- No se define si el costo de alquiler debe distribuirse por días o registrarse completo en el mes de inicio.
- No se especifica si auxilios `en_proceso` deben contar como auxilios netos.

## 9. Supuestos tomados para el dashboard

- El costo del alquiler se asigna al mes de `fecha_inicio`.
- Los auxilios cancelados no cuentan dentro de la cantidad neta.
- Los registros con CEDI no encontrado no se eliminan; se muestran como `Sin territorio`.
- Metabase consulta tablas en `MARTS`, no tablas `RAW`.

## 10. Archivos entregados

- `prueba_tecnica_snowflake_sodas.sql`: contiene DDL, validaciones, modelos SQL y queries de dashboard.
- `prueba_tecnica_snowflake_sodas.yml`: contiene tests dbt de calidad.
- `README.md`: contiene arquitectura, decisiones, supuestos y documentación general.
