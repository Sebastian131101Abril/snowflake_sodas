# Snowflake / dbt / Metabase / SODAS SAS

## 1. Conceptos Fundamentales
### Arquitectura popuesta
Flujo general:

Cloud SQL PostgreSQL → Fivetran → Snowflake → dbt → Metabase

En Snowflake organizaría la información por capas, separando los datos crudos de los modelos que ya están preparados para análisis. Esto permite tener mayor orden, trazabilidad y control sobre las transformaciones realizadas.

La capa RAW mantendría la información tal como llega desde la fuente, mientras que las capas de staging, intermedias y marts se usarían para limpiar, transformar y dejar los datos listos para consumo en herramientas como Metabase.

Además, tendría en cuenta la forma en que Snowflake optimiza las consultas mediante micro partitions. Por eso, al diseñar los modelos, revisaría cuáles son los filtros más usados por los usuarios, por ejemplo fechas, cliente, CEDI o territorio. Con base en eso se podrían tomar decisiones de modelado y, si el volumen lo justifica, evaluar estrategias como clustering para mejorar el rendimiento sin aumentar innecesariamente el costo. De la siguiente manera:

- RAW: datos crudos provenientes de Fivetran o archivos externos.
- STAGING: limpieza, tipado, normalización y deduplicación básica.
- INTERMEDIATE: reglas de negocio y joins reutilizables.
- MARTS: tablas finales optimizadas para consumo en Metabase.
- AUDIT: control de cargas, manifiestos, errores y alertas.

### Convenciones de nomenclatura

Utilizaria la convención snake_case y prefijos según la capa de esta manera:

- `stg_`: modelos staging.
- `int_`: modelos intermedios.
- `dim_`: dimensiones.
- `fct_`: tablas de hechos.
- `agg_`: tablas agregadas.
- `mart_`: modelos finales de negocio.

### Criterios de materialización dbt
Depende el dbt
#### Si es View

La usaria cuando el modelo sea liviano, tenga pocas transformaciones y se use como capa de limpieza inicial, pues no duplica almacenamiento y siempre lee la data más reciente.

#### Si es Table

La usuaria cuano el modelo tenga lógica pesada, joins, agregaciones o sea consumido directamente por dashboards. Esta tiene un mejor rendimiento para BI y tambien evita recalcular transformaciones complejas en cada consulta.

#### Si es Incremental

La Usaria cuando la tabla crezca continuamente y pueda cargarse por fecha, timestamp o llave de negocio, estos ultimos deben ser confiables.

### Dashboard lento en Metabase

Según la documentación de Metabase se recomienda revisar dashboards lentos considerando cantidad de tarjetas, consultas en cola, concurrencia, caché y consultas pesadas.
1. Identificar si el problema está en Metabase o Snowflake.
   - ¿Todas las tarjetas son lentas o solo una?
   - ¿El dashboard tiene muchos filtros?
2. Revisar Query History y Query Profile en Snowflake pues permite revisar y explorar el Query Profile para ver los pasos de ejecución y los nodos más costosos de una consulta.
   - Query ID de las consultas lanzadas por Metabase.
   - Tiempo total de ejecución.
   - Joins costosos.
4. Revisar el modelo dbt que alimenta el dashboard.
   - Si Metabase consulta directamente eso sería una mala práctica para KPIs financieros. Lo correcto sería crear una tabla o agregado en dbt.
6. Revisar optimizaciones posibles.
   - Cambiar vistas pesadas por tablas o incrementales.
   - Crear agregados mensuales para KPIs financieros.
   - Evitar SELECT *.
   
### Snowflake y costos
Problemas detectados en el query:
- El `SELECT *`. Traer todas las columnas aumenta el volumen escaneado y transferido. En Snowflake conviene seleccionar solo las columnas necesarias, especialmente si hay columnas grandes como metadata VARIANT.
- Tiene un filtro demasiado amplio para una ejecución cada hora. Filtra todo desde el 1 de enero de 2024. Eso hace que el escaneo crezca cada vez más. Si el proceso es horario, usaría una ventana incremental o construiría un modelo incremental en dbt con unique_key = inspection_id.
- El `ORDER BY` es costoso e innecesario para procesos batch pues ordenar todo el resultado por fecha puede ser caro, especialmente si no hay LIMIT o si el ordenamiento no es requerido para una tabla final. Si es solo para mostrar los últimos registros agregarle un `LIMIT 100`
  
Caracteristicas de snowflake que pueden servir:
- Falta estrategia de clustering pues si inspections es una tabla grande y se filtra frecuentemente por fecha, evaluaría clustering por fecha o por combinación de fecha y cliente. No lo aplicaría automáticamente. Primero revisaría el Query Profile y funciones como SYSTEM$CLUSTERING_INFORMATION. Snowflake recomienda evaluar bien las clustering keys y evitar demasiadas columnas; para la mayoría de tablas recomienda máximo 3 o 4 columnas o expresiones en la key.
- Un warehouse XL puede ser innecesario para una consulta que debería resolverse con un modelo agregado o incremental. Revisaría Query History, duración, bytes escaneados y concurrencia antes de escalar. Snowflake permite configurar auto suspend y auto resume en warehouses para controlar consumo cuando no hay actividad.

## Caso Real — Integración SODAS SAS
Revisar el archivo .yml se encuentran las pruebas de calidad y documentación de modelos dbt.

### Mecanismo para que SODAS cargue su data
SODAS no tiene equipo técnico y la data llega de forma esporádica. Por eso, evitaría una integración compleja al inicio.

Se recomienda que SODAS cargue archivos CSV en una carpeta cloud controlada o stage externo.

Los flujos propuestos son los siguientes:

Opción A (Recomendada): Es el mejor equilibrio entre simplicidad para SODAS, control operativo, auditoría y automatización. Para una fase posterior, se puede construir un portal que deje los archivos en el mismo stage.
Se recomienda que SODAS cargue archivos CSV en una carpeta cloud controlada o stage externo.

Ventajas
1. SODAS descarga una plantilla oficial.
2. SODAS diligencia los archivos de auxilios y alquileres.
3. SODAS sube los archivos a una carpeta controlada.
4. Snowflake carga los archivos a tablas RAW landing.
5. Se registra la carga en tablas de auditoría.
6. dbt limpia, tipa y deduplica la información.
7. dbt cruza la data con geo_distribution.
8. dbt construye tablas finales en MARTS.
9. Metabase consume únicamente tablas finales o agregadas.

Contras
1. Requiere configurar storage externo o una zona de carga.
2. SODAS debe respetar plantilla y formato.
3. Se necesita control de permisos.

Esfuerzo: Medio.

Opción B:
Construir un portal pequeño, por ejemplo con Streamlit, Retool o aplicación interna, donde SODAS cargue el archivo y vea errores básicos.

Ventajas
1. Mejor experiencia para usuario no técnico.
2. Validaciones antes de cargar.
3. Menos errores de formato.
4. Puede mostrar histórico de cargas.

Contras
1. Mayor esfuerzo de desarrollo.
2. Requiere autenticación, backend y mantenimiento.

Esfuerzo: Medio - Alto

### Garantizar completitud y evitar duplicados
Implementaría una tabla de control (query en el archivo .sql)

Validaciones:
1. Validar estructura del archivo antes de cargar.
2. Validar columnas obligatorias.
3. Validar tipos de datos.
4. Validar estados permitidos.
5. Validar que auxilio_id y alquiler_id no vengan nulos.
6. Validar duplicados por llave de negocio.
7. Validar cantidad de filas cargadas vs filas esperadas.
8. Registrar batch_id y archivo fuente.
9. No mezclar cargas manuales y Snowpipe sobre la misma ruta.

### Schemas y modelos dbt para SODAS
Estructuraría la integración por capas, separando la data cruda, la limpieza, el enriquecimiento y los modelos finales que va a consumir Metabase. La idea es no cruzar directamente los archivos de SODAS desde la capa RAW, sino primero normalizarlos y validarlos.

En la capa RAW dejaría los datos tal como llegan desde SODAS y la tabla existente geo_distribution. A las tablas de SODAS les agregaría columnas técnicas como batch_id, source_file, ingested_at y row_hash, para tener trazabilidad de cada archivo cargado.

En la capa STAGING haría la limpieza básica normalizar nombres, convertir tipos de datos, limpiar espacios, pasar el cedi a mayúsculas y deduplicar por la llave de negocio. Para auxilios usaría auxilio_id y para alquileres alquiler_id.

También crearía un modelo stg_geo_distribution, dejando una sola versión por cedi, tomando la más reciente con updated_at.

En la capa INTERMEDIATE haría el cruce entre SODAS y geo_distribution. Usaría LEFT JOIN para no perder registros operativos si llega un cedi que todavía no existe en la tabla de segmentación. Eso permite mostrar el dato como pendiente de calidad y corregirlo después.

Finalmente, en la capa MARTS dejaría las tablas listas para Metabase, ya con los campos de segmentación incluidos. También construiría tablas agregadas si el dashboard necesita mejor rendimiento.

En dbt agregaría pruebas de calidad en el .yml, principalmente:
- auxilio_id único y no nulo.
- alquiler_id único y no nulo.
- cedi no nulo.
- cedi relacionado con stg_geo_distribution.
- estados válidos para auxilios.
- costo no nulo para alquileres.
- fecha_inicio y fecha_auxilio no nulas.

En resumen, la integración quedaría así:

Archivos SODAS -> RAW landing -> STAGING: limpieza, tipado y deduplicación -> INTERMEDIATE: cruce con geo_distribution por CEDI -> MARTS: tablas finales para Metabase -> Dashboard SODAS

Con esta estructura se mantiene trazabilidad, se evita consultar datos crudos directamente y se deja una capa final más estable y optimizada para análisis.

### Validaciones y alertas si SODAS no envía datos
Crearía una tabla de expectativas y consultas de alerta: (querys en el archivo .sql)
Pues Snowflake tiene Alerts para ejecutar acciones o enviar notificaciones cuando se cumple una condición, y también permite enviar notificaciones por email mediante notification integrations.

### Flujo completo SODAS → Snowflake → dbt → Metabase

1. SODAS descarga una plantilla oficial CSV.
2. SODAS diligencia auxilios viales y alquileres.
3. SODAS sube los archivos a una carpeta cloud controlada.
4. Snowflake detecta o procesa los archivos desde un stage.
5. Se valida estructura, tipos de datos y columnas obligatorias.
6. Se carga a tablas RAW landing con batch_id, source_file e ingested_at.
7. Se registra la carga en audit.sodas_file_manifest.
8. dbt ejecuta modelos STAGING:
   - limpieza
   - tipado
   - normalización
   - deduplicación
9. dbt ejecuta modelos INTERMEDIATE:
   - join con geo_distribution
   - enriquecimiento con territory, logistic_operator e inspection_site
10. dbt ejecuta MARTS.
11. dbt ejecuta tests de calidad.
12. Si falla una validación, se genera alerta.
13. Metabase consulta solo tablas MARTS o agregados.
14. El dashboard muestra métricas operacionales para SODAS.

Para orquestación interna, Snowflake Tasks puede ejecutar SQL o procedimientos en un horario, usando warehouse administrado por el usuario o ejecución serverless.

## Queries del dashboard en Metabase

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
- No se aclara si geo_distribution debe manejar histórico tipo SCD.
- No se define si el costo de alquiler debe distribuirse por días o registrarse completo en el mes de inicio.
- No se especifica si auxilios en_proceso deben contar como auxilios netos.

## 9. Supuestos tomados para el dashboard

- El costo del alquiler se asigna al mes de fecha_inicio.
- Los auxilios cancelados no cuentan dentro de la cantidad neta.
- Los registros con CEDI no encontrado no se eliminan; se muestran como Sin territorio.
- Metabase consulta tablas en MARTS, no tablas RAW.

