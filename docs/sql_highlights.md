# SQL highlights

Esta selección resume las consultas que mejor demuestran habilidades de Data Analytics.
El modelo completo está en `sql/02_marts.sql`; aquí se muestran patrones representativos.

## 1. Panel común con CTE, grilla y `HAVING`

**Pregunta:** ¿qué GTIN puede compararse justamente entre las siete cadenas cada día?

```sql
WITH scope_size AS (
    SELECT build_id, scope_version, COUNT(*) AS expected_banners
    FROM dim_banner_scope
    GROUP BY build_id, scope_version
), healthy_scope_day AS (
    SELECT h.build_id, h.scope_version, h.snapshot_date
    FROM mart_banner_day_health AS h
    INNER JOIN scope_size AS s USING (build_id, scope_version)
    GROUP BY h.build_id, h.scope_version, h.snapshot_date, s.expected_banners
    HAVING COUNT(*) FILTER (WHERE h.source_healthy) = s.expected_banners
), common_gtin AS (
    SELECT p.build_id, p.scope_version, p.snapshot_date, p.gtin14,
           COUNT(*) AS observed_banners
    FROM mart_banner_product_daily AS p
    INNER JOIN healthy_scope_day AS d
        USING (build_id, scope_version, snapshot_date)
    GROUP BY p.build_id, p.scope_version, p.snapshot_date, p.gtin14
)
SELECT g.build_id, g.scope_version, g.snapshot_date, g.gtin14
FROM common_gtin AS g
INNER JOIN scope_size AS s USING (build_id, scope_version)
WHERE g.observed_banners = s.expected_banners;
```

Demuestra CTEs, agregación condicional, joins y control explícito de comparabilidad.

## 2. Índice geométrico y benchmark común

**Pregunta:** ¿qué cadena tiene un nivel relativo más bajo sobre exactamente los mismos productos?

```sql
WITH benchmark AS (
    SELECT p.build_id, p.scope_version, p.snapshot_date, p.gtin14,
           exp(avg(ln(p.banner_price))) AS benchmark_price
    FROM mart_banner_product_daily AS p
    INNER JOIN bridge_index_common_gtin_daily AS g
        USING (build_id, scope_version, snapshot_date, gtin14)
    GROUP BY p.build_id, p.scope_version, p.snapshot_date, p.gtin14
)
SELECT
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    100 * exp(avg(ln(p.banner_price / b.benchmark_price))) AS price_index,
    COUNT(*) AS common_gtins
FROM mart_banner_product_daily AS p
INNER JOIN benchmark AS b
    USING (build_id, scope_version, snapshot_date, gtin14)
GROUP BY p.snapshot_date, p.id_comercio, p.id_bandera;
```

Demuestra transformaciones logarítmicas, media geométrica y construcción de KPI.

## 3. Cobertura con funciones ventana

**Pregunta:** ¿un descenso de precios es real o el día perdió sucursales informantes?

```sql
WITH baseline AS (
    SELECT
        q.*,
        median(q.source_rows) OVER () AS median_rows_7d,
        median(q.reporting_stores) OVER () AS median_stores_7d
    FROM mart_quality_daily AS q
)
SELECT
    *,
    source_rows / nullif(median_rows_7d, 0) AS row_coverage_ratio,
    reporting_stores / nullif(median_stores_7d, 0) AS store_coverage_ratio,
    source_rows >= 0.80 * median_rows_7d
        AND reporting_stores >= 0.80 * median_stores_7d AS source_healthy
FROM baseline;
```

Demuestra funciones ventana, medianas robustas, `NULLIF` y reglas de calidad.

## 4. Detección temporal con `LAG`

**Pregunta:** ¿qué precios saltan abruptamente de un día al siguiente?

```sql
WITH lagged AS (
    SELECT
        p.*,
        lag(snapshot_date) OVER w AS previous_date,
        lag(list_price) OVER w AS previous_price
    FROM fct_analysis_price_store_daily AS p
    WINDOW w AS (
        PARTITION BY build_id, id_comercio, id_bandera, id_sucursal, gtin14
        ORDER BY snapshot_date
    )
)
SELECT
    *,
    list_price / nullif(previous_price, 0) AS price_ratio,
    CASE
        WHEN list_price / nullif(previous_price, 0) NOT BETWEEN 0.5 AND 2
            THEN 'CRITICAL'
        ELSE 'WARNING'
    END AS severity
FROM lagged
WHERE date_diff('day', previous_date, snapshot_date) = 1
  AND previous_price > 0
  AND list_price / previous_price NOT BETWEEN 0.667 AND 1.5;
```

Demuestra análisis temporal, ventanas, partición por entidad y clasificación con `CASE`.

## 5. Percentiles y `GROUPING SETS`

**Pregunta:** ¿cómo cambia la dispersión por cadena, provincia y combinación?

```sql
SELECT
    snapshot_date,
    gtin14,
    CASE
        WHEN grouping(id_comercio) = 1 AND grouping(provincia_codigo) = 1
            THEN 'NATIONAL'
        WHEN grouping(id_comercio) = 0 AND grouping(provincia_codigo) = 1
            THEN 'BANNER'
        WHEN grouping(id_comercio) = 1 AND grouping(provincia_codigo) = 0
            THEN 'PROVINCE'
        ELSE 'BANNER_PROVINCE'
    END AS dispersion_level,
    id_comercio,
    id_bandera,
    provincia_codigo,
    COUNT(*) AS stores_raw,
    median(list_price) AS price_median,
    quantile_cont(list_price, 0.10) AS price_p10,
    quantile_cont(list_price, 0.90) AS price_p90
FROM fct_analysis_price_store_daily
GROUP BY GROUPING SETS (
    (snapshot_date, gtin14),
    (snapshot_date, gtin14, id_comercio, id_bandera),
    (snapshot_date, gtin14, provincia_codigo),
    (snapshot_date, gtin14, id_comercio, id_bandera, provincia_codigo)
);
```

Demuestra percentiles, agregación multidimensional y reutilización de lógica.

## 6. Canasta completa y cobertura de negocio

**Pregunta:** ¿cuánto cuesta la misma canasta y cuándo el resultado es publicable?

```sql
SELECT
    build_id,
    basket_version,
    snapshot_date,
    id_comercio,
    id_bandera,
    COUNT(*) AS active_stores,
    COUNT(*) FILTER (WHERE complete_basket) AS complete_stores,
    COUNT(*) FILTER (WHERE complete_basket)::DOUBLE / COUNT(*) AS completion_rate,
    median(observed_cost) FILTER (WHERE complete_basket) AS branch_median_cost,
    CASE
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 20 THEN 'PUBLISHABLE'
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 5 THEN 'DIRECTIONAL'
        ELSE 'SUPPRESSED'
    END AS coverage_status
FROM mart_basket_store_daily
GROUP BY build_id, basket_version, snapshot_date, id_comercio, id_bandera;
```

Demuestra agregación filtrada, KPI de cobertura y traducción de una regla de negocio a SQL.

## Skills demonstrated

- CTEs y composición de consultas.
- Joins con grano explícito.
- Funciones ventana: `LAG`, `ROW_NUMBER`, medianas móviles.
- Percentiles exactos y agregaciones filtradas.
- `GROUPING SETS` para análisis multidimensional.
- Series temporales y detección de cambios.
- `CASE WHEN` para reglas de publicación.
- Diseño de métricas robustas y comparables.
