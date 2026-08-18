CREATE OR REPLACE TABLE dim_banner_daily AS
SELECT
    ctx.build_id,
    c.snapshot_date,
    c.id_comercio,
    c.id_bandera,
    c.comercio_cuit,
    c.comercio_razon_social,
    c.comercio_bandera_nombre,
    c.comercio_bandera_url,
    c.comercio_ultima_actualizacion,
    c.comercio_version_sepa
FROM commerce_snapshot AS c
INNER JOIN build_inputs AS i
    ON c.ingest_run_id = i.ingest_run_id AND c.snapshot_date = i.snapshot_date
CROSS JOIN build_context AS ctx
WHERE i.build_id = ctx.build_id
    AND c.id_comercio IS NOT NULL
    AND c.id_bandera IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY c.snapshot_date, c.id_comercio, c.id_bandera
    ORDER BY c.comercio_ultima_actualizacion DESC NULLS LAST,
             c.source_package DESC,
             c.comercio_bandera_nombre DESC NULLS LAST
) = 1;

CREATE OR REPLACE TABLE dim_store_daily AS
SELECT
    ctx.build_id,
    s.snapshot_date,
    s.id_comercio,
    s.id_bandera,
    s.id_sucursal,
    s.sucursal_nombre,
    s.sucursal_tipo,
    s.calle,
    s.numero,
    s.latitud,
    s.longitud,
    s.barrio,
    s.codigo_postal,
    s.localidad,
    s.provincia_codigo,
    s.coordenadas_validas
FROM store_snapshot AS s
INNER JOIN build_inputs AS i
    ON s.ingest_run_id = i.ingest_run_id AND s.snapshot_date = i.snapshot_date
CROSS JOIN build_context AS ctx
WHERE i.build_id = ctx.build_id
    AND s.id_comercio IS NOT NULL
    AND s.id_bandera IS NOT NULL
    AND s.id_sucursal IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY s.snapshot_date, s.id_comercio, s.id_bandera, s.id_sucursal
    ORDER BY s.source_package DESC,
             s.sucursal_nombre DESC NULLS LAST,
             s.provincia_codigo DESC NULLS LAST
) = 1;

CREATE OR REPLACE TABLE dim_product_variant_asof AS
WITH variants AS (
    SELECT
        p.gtin14,
        p.producto_descripcion,
        p.producto_descripcion_normalizada,
        p.marca,
        p.cantidad_presentacion,
        p.unidad_presentacion,
        COUNT(*) AS observations,
        max(p.snapshot_date) AS last_seen,
        max(p.source_package) AS last_package
    FROM fact_price AS p
    INNER JOIN build_inputs AS i
        ON p.ingest_run_id = i.ingest_run_id AND p.snapshot_date = i.snapshot_date
    CROSS JOIN build_context AS ctx
    WHERE i.build_id = ctx.build_id
        AND p.product_code_scope = 'GLOBAL_GTIN'
    GROUP BY
        p.gtin14,
        p.producto_descripcion,
        p.producto_descripcion_normalizada,
        p.marca,
        p.cantidad_presentacion,
        p.unidad_presentacion
)
SELECT
    ctx.build_id,
    r.*,
    CASE
        WHEN r.unidad_presentacion = 'KG' THEN r.cantidad_presentacion * 1000
        WHEN r.unidad_presentacion = 'G' THEN r.cantidad_presentacion
        WHEN r.unidad_presentacion = 'L' THEN r.cantidad_presentacion * 1000
        WHEN r.unidad_presentacion = 'ML' THEN r.cantidad_presentacion
        WHEN r.unidad_presentacion = 'UN' THEN r.cantidad_presentacion
    END AS cantidad_base,
    CASE
        WHEN r.unidad_presentacion IN ('KG', 'G') THEN 'G'
        WHEN r.unidad_presentacion IN ('L', 'ML') THEN 'ML'
        WHEN r.unidad_presentacion = 'UN' THEN 'UN'
    END AS unidad_base,
FROM variants AS r
CROSS JOIN build_context AS ctx;

CREATE OR REPLACE TABLE dim_product_asof AS
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY build_id, gtin14
        ORDER BY observations DESC, last_seen DESC, last_package DESC,
                 producto_descripcion_normalizada DESC NULLS LAST,
                 marca DESC NULLS LAST, cantidad_presentacion DESC NULLS LAST,
                 unidad_presentacion DESC NULLS LAST
    ) AS variant_rank
    FROM dim_product_variant_asof
)
SELECT
    r.build_id,
    ctx.as_of_date,
    r.gtin14,
    r.producto_descripcion,
    r.producto_descripcion_normalizada,
    r.marca,
    r.cantidad_presentacion,
    r.unidad_presentacion,
    r.cantidad_base,
    r.unidad_base,
    r.observations,
    r.last_seen
FROM ranked AS r
CROSS JOIN build_context AS ctx
WHERE r.variant_rank = 1;

CREATE OR REPLACE TABLE fct_global_price_store_daily AS
SELECT
    ctx.build_id,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.id_sucursal,
    p.gtin14,
    'GLOBAL_GTIN' AS product_code_scope,
    p.precio_lista AS list_price,
    p.precio_lista AS source_price_min,
    p.precio_lista AS source_price_max,
    1::BIGINT AS source_rows,
    1::BIGINT AS distinct_source_prices
FROM fact_price AS p
INNER JOIN build_inputs AS i
    ON p.ingest_run_id = i.ingest_run_id AND p.snapshot_date = i.snapshot_date
CROSS JOIN build_context AS ctx
WHERE i.build_id = ctx.build_id
    AND p.product_code_scope = 'GLOBAL_GTIN'
    AND p.precio_lista_valido
    AND p.id_comercio IS NOT NULL
    AND p.id_bandera IS NOT NULL
    AND p.id_sucursal IS NOT NULL;

CREATE OR REPLACE TABLE fct_local_price_store_daily AS
SELECT
    ctx.build_id,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.id_sucursal,
    p.id_producto,
    p.product_code_scope,
    md5(concat_ws('|', p.id_comercio, p.id_bandera, p.id_producto)) AS local_product_key,
    max(p.producto_descripcion) AS producto_descripcion,
    max(p.marca) AS marca,
    median(p.precio_lista) AS list_price,
    median(CASE
        WHEN p.unidad_referencia = 'KG' THEN p.precio_referencia / nullif(p.cantidad_referencia, 0)
        WHEN p.unidad_referencia = 'G' THEN p.precio_referencia * 1000 / nullif(p.cantidad_referencia, 0)
    END) AS reference_price_per_kg,
    median(CASE
        WHEN p.unidad_referencia = 'L' THEN p.precio_referencia / nullif(p.cantidad_referencia, 0)
        WHEN p.unidad_referencia = 'ML' THEN p.precio_referencia * 1000 / nullif(p.cantidad_referencia, 0)
    END) AS reference_price_per_litre,
    median(CASE
        WHEN p.unidad_referencia = 'UN' THEN p.precio_referencia / nullif(p.cantidad_referencia, 0)
    END) AS reference_price_per_unit,
    COUNT(*) AS source_rows
FROM fact_price AS p
INNER JOIN build_inputs AS i
    ON p.ingest_run_id = i.ingest_run_id AND p.snapshot_date = i.snapshot_date
CROSS JOIN build_context AS ctx
WHERE i.build_id = ctx.build_id
    AND p.product_code_scope IN ('RESTRICTED_LOCAL', 'INTERNAL_LOCAL')
    AND p.precio_lista_valido
    AND p.id_comercio IS NOT NULL
    AND p.id_bandera IS NOT NULL
    AND p.id_sucursal IS NOT NULL
GROUP BY
    ctx.build_id,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.id_sucursal,
    p.id_producto,
    p.product_code_scope;

CREATE OR REPLACE TABLE mart_price_product_daily AS
WITH aggregated AS (
    SELECT
        p.build_id,
        p.snapshot_date,
        p.gtin14,
        p.id_comercio,
        p.id_bandera,
        coalesce(s.provincia_codigo, 'SIN_DATO') AS provincia_codigo,
        COUNT(*) AS reporting_stores,
        quantile_cont(p.list_price, [0.10, 0.50, 0.90]) AS price_quantiles,
        min(p.list_price) AS price_min,
        max(p.list_price) AS price_max
    FROM fct_global_price_store_daily AS p
    LEFT JOIN dim_store_daily AS s
        USING (build_id, snapshot_date, id_comercio, id_bandera, id_sucursal)
    GROUP BY
        p.build_id, p.snapshot_date, p.gtin14, p.id_comercio,
        p.id_bandera, coalesce(s.provincia_codigo, 'SIN_DATO')
)
SELECT
    * EXCLUDE (price_quantiles),
    price_quantiles[2] AS price_median,
    price_quantiles[1] AS price_p10,
    price_quantiles[3] AS price_p90
FROM aggregated;

CREATE OR REPLACE TABLE mart_quality_daily AS
SELECT
    ctx.build_id,
    p.snapshot_date,
    COUNT(*) AS source_rows,
    COUNT(DISTINCT concat_ws('|', p.id_comercio, p.id_bandera, p.id_sucursal))
        FILTER (WHERE p.id_sucursal IS NOT NULL) AS reporting_stores,
    COUNT(DISTINCT p.gtin14) FILTER (WHERE p.product_code_scope = 'GLOBAL_GTIN')
        AS global_gtins,
    COUNT(*) FILTER (WHERE p.product_code_scope = 'GLOBAL_GTIN') AS global_gtin_rows,
    COUNT(*) FILTER (WHERE p.product_code_scope = 'RESTRICTED_LOCAL') AS restricted_local_rows,
    COUNT(*) FILTER (WHERE p.product_code_scope = 'INTERNAL_LOCAL') AS internal_local_rows,
    COUNT(*) FILTER (WHERE p.product_code_scope = 'INVALID') AS invalid_code_rows,
    COUNT(*) FILTER (WHERE NOT p.precio_lista_valido) AS invalid_list_price_rows,
    COUNT(*) FILTER (WHERE p.id_comercio IS NULL OR p.id_bandera IS NULL
        OR p.id_sucursal IS NULL OR p.id_producto IS NULL) AS null_key_rows,
    COUNT(*) FILTER (WHERE p.precio_promo_general > 0) AS general_promotion_rows,
    COUNT(*) FILTER (WHERE p.precio_promo_segmentada > 0) AS segmented_promotion_rows
FROM fact_price AS p
INNER JOIN build_inputs AS i
    ON p.ingest_run_id = i.ingest_run_id AND p.snapshot_date = i.snapshot_date
CROSS JOIN build_context AS ctx
WHERE i.build_id = ctx.build_id
GROUP BY ctx.build_id, p.snapshot_date;

CREATE OR REPLACE TABLE mart_snapshot_health AS
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

CREATE OR REPLACE TABLE dim_banner_scope AS
SELECT * FROM (
    VALUES
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '10', '1', 'CARREFOUR', 'Hipermercado Carrefour', 'Bandera de mayor surtido'),
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '12', '1', 'COTO', 'COTO', 'Grupo independiente'),
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '11', '2', 'CHANGOMAS', 'Changomas', 'Bandera principal'),
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '15', '1', 'DIA', 'DIA', 'Formato descuento'),
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '2', '1', 'LA_ANONIMA', 'La Anonima', 'Cobertura regional amplia'),
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '9', '3', 'CENCOSUD', 'Jumbo', 'Mayor surtido del grupo'),
        ((SELECT build_id FROM build_context), 'IDX_GROCERY_7_V1', '13', '1', 'COOPERATIVA_OBRERA', 'Cooperativa Obrera', 'Grupo independiente')
) AS scope(build_id, scope_version, id_comercio, id_bandera, corporate_group, banner_label, inclusion_reason);

CREATE OR REPLACE TABLE mart_banner_day_health AS
WITH dates AS (
    SELECT unnest(generate_series(ctx.window_start, ctx.as_of_date, INTERVAL 1 DAY))::DATE
        AS snapshot_date
    FROM build_context AS ctx
), actual AS (
    SELECT
        p.snapshot_date,
        p.id_comercio,
        p.id_bandera,
        COUNT(*) AS source_rows,
        COUNT(DISTINCT p.id_sucursal) AS reporting_stores,
        COUNT(DISTINCT p.gtin14) AS reported_gtins
    FROM fct_global_price_store_daily AS p
    GROUP BY p.snapshot_date, p.id_comercio, p.id_bandera
), grid AS (
    SELECT
        s.build_id,
        s.scope_version,
        d.snapshot_date,
        s.id_comercio,
        s.id_bandera,
        s.banner_label,
        coalesce(a.source_rows, 0) AS source_rows,
        coalesce(a.reporting_stores, 0) AS reporting_stores,
        coalesce(a.reported_gtins, 0) AS reported_gtins
    FROM dates AS d
    CROSS JOIN dim_banner_scope AS s
    LEFT JOIN actual AS a
        ON d.snapshot_date = a.snapshot_date
        AND s.id_comercio = a.id_comercio
        AND s.id_bandera = a.id_bandera
), baseline AS (
    SELECT
        *,
        median(source_rows) OVER (PARTITION BY id_comercio, id_bandera) AS median_rows_7d,
        median(reporting_stores) OVER (PARTITION BY id_comercio, id_bandera) AS median_stores_7d
    FROM grid
)
SELECT
    *,
    source_rows / nullif(median_rows_7d, 0) AS row_coverage_ratio,
    reporting_stores / nullif(median_stores_7d, 0) AS store_coverage_ratio,
    source_rows >= 0.80 * median_rows_7d
        AND reporting_stores >= 0.80 * median_stores_7d
        AND reporting_stores > 0 AS source_healthy
FROM baseline;

CREATE OR REPLACE TABLE mart_banner_product_daily AS
SELECT
    p.build_id,
    s.scope_version,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.gtin14,
    median(p.list_price) AS banner_price,
    COUNT(*) AS reporting_stores
FROM fct_global_price_store_daily AS p
INNER JOIN dim_banner_scope AS s
    ON p.build_id = s.build_id
    AND p.id_comercio = s.id_comercio
    AND p.id_bandera = s.id_bandera
INNER JOIN mart_banner_day_health AS h
    ON p.build_id = h.build_id
    AND p.snapshot_date = h.snapshot_date
    AND p.id_comercio = h.id_comercio
    AND p.id_bandera = h.id_bandera
WHERE h.source_healthy
GROUP BY
    p.build_id, s.scope_version, p.snapshot_date,
    p.id_comercio, p.id_bandera, p.gtin14;

CREATE OR REPLACE TABLE mart_product_persistence_7d AS
WITH daily AS (
    SELECT
        p.build_id,
        p.id_comercio,
        p.id_bandera,
        p.gtin14,
        p.snapshot_date,
        p.reporting_stores AS stores_with_product,
        h.reporting_stores,
        p.reporting_stores::DOUBLE / nullif(h.reporting_stores, 0)
            AS store_coverage
    FROM mart_banner_product_daily AS p
    INNER JOIN mart_banner_day_health AS h
        ON p.build_id = h.build_id
        AND p.snapshot_date = h.snapshot_date
        AND p.id_comercio = h.id_comercio
        AND p.id_bandera = h.id_bandera
    WHERE h.source_healthy
), healthy_days AS (
    SELECT
        build_id,
        id_comercio,
        id_bandera,
        COUNT(*) FILTER (WHERE source_healthy) AS source_healthy_days
    FROM mart_banner_day_health
    GROUP BY build_id, id_comercio, id_bandera
)
SELECT
    d.build_id,
    ctx.as_of_date AS window_end,
    d.id_comercio,
    d.id_bandera,
    d.gtin14,
    h.source_healthy_days,
    COUNT(*) AS observed_healthy_days,
    COUNT(*)::DOUBLE / nullif(h.source_healthy_days, 0)
        AS conditional_persistence,
    COUNT(*) / 7.0 AS calendar_persistence,
    median(d.store_coverage) AS median_store_coverage,
    min(d.store_coverage) AS minimum_store_coverage,
    h.source_healthy_days = 7 AND COUNT(*) = 7
        AS strict_persistent_7d
FROM daily AS d
INNER JOIN healthy_days AS h USING (build_id, id_comercio, id_bandera)
CROSS JOIN build_context AS ctx
GROUP BY
    d.build_id, ctx.as_of_date, d.id_comercio, d.id_bandera,
    d.gtin14, h.source_healthy_days;

CREATE OR REPLACE TABLE dim_basket_version AS
SELECT
    ctx.build_id,
    'CANASTA_2026W31_V1' AS basket_version,
    'Canasta comparable de supermercado' AS basket_name,
    DATE '2026-07-27' AS valid_from,
    NULL::DATE AS valid_to,
    'PUBLISHED' AS status,
    'LIST' AS price_type,
    'Ocho GTIN exactos; presentacion fija; sin promociones ni imputacion.' AS methodology_note
FROM build_context AS ctx;

CREATE OR REPLACE TABLE dim_basket_component AS
SELECT * FROM (
    VALUES
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 1, 'ACEITE', 'Aceite de girasol', '07790272001029', 'Aceite Natura girasol 1,5 L', 1500.0, 'ML', 'ACEITE.*GIRASOL', 'OLIVA|MEZCLA|AEROSOL', 'Presentacion exacta y alta cobertura'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 2, 'ARROZ', 'Arroz blanco', '07791120031557', 'Arroz Ala blanco 1 kg', 1000.0, 'G', '(^| )ARROZ( |$).*(BLANCO|LARGO FINO)', 'INTEGRAL|PARBOIL|DORADO|PREPARADO|GALLET|TOST', 'Arroz blanco sin preparacion'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 3, 'AZUCAR', 'Azucar blanca comun', '07792540250450', 'Azucar Ledesma superior 1 kg', 1000.0, 'G', '(^| )AZUCAR( |$)', 'HILERET.*LIGHT|LIGHT|DIET|EDULCOR|ENDULZ|STEVIA|SUCRAL|MASCAB|NEGRA|RUBIA|IMPALPABLE|SIN AZUCAR|S/AZUCAR', 'Excluye edulcorantes y variantes light'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 4, 'CAFE', 'Cafe tostado molido', '07790550022234', 'Cafe Cabrales tostado molido 250 g', 250.0, 'G', 'CAFE.*(TOSTADO.*)?MOLIDO', 'INSTANT|CAPSUL|SAQUIT|DESCAFEIN|MOCHA', 'Forma de consumo homogenea'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 5, 'FIDEOS', 'Fideos secos', '07790070320285', 'Fideos Favorita secos 500 g', 500.0, 'G', 'FIDEO.*(SECO|SPAGHETTI)|FIDEOS.*SECOS', 'SOPA|RELLENO|RAVIO|CAPEL|ÑOQUI|FRESCO', 'Pasta seca simple'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 6, 'HARINA', 'Harina de trigo 000', '07790070562258', 'Harina Favorita 000 1 kg', 1000.0, 'G', 'HARINA.*(TRIGO.*)?000([^0-9]|$)', '0000|INTEGRAL|ORGANIC|PREMEZCLA|LEUDANTE', 'Tipo 000 exacto'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 7, 'LECHE', 'Leche entera UHT', '07790742363008', 'Leche La Serenisima entera UHT 1 L', 1000.0, 'ML', 'LECHE.*(ENTERA.*)?(UAT|UHT|LARGA VIDA|L\\.V|3%)', 'POLVO|INFANTIL|DESCREM|PARCIAL|SABORIZ', 'Leche entera de larga vida'),
        ((SELECT build_id FROM build_context), 'CANASTA_2026W31_V1', 8, 'YERBA', 'Yerba mate tradicional', '07792710000182', 'Yerba Amanda tradicional 500 g', 500.0, 'G', 'YERBA.*MATE.*TRADICIONAL', 'SUAVE|HIERBAS|SERRANA|SABORIZ|COMPUESTA', 'Yerba tradicional sin variantes')
) AS component(
    build_id, basket_version, component_order, category_id, category_name,
    gtin14, canonical_product_name, target_quantity_base, target_base_unit,
    include_regex, exclude_regex, selection_rationale
);

CREATE OR REPLACE TABLE mart_basket_candidate_review AS
SELECT
    c.build_id,
    c.basket_version,
    c.category_id,
    p.gtin14,
    p.producto_descripcion,
    p.marca,
    p.cantidad_base,
    p.unidad_base,
    p.gtin14 = c.gtin14 AS selected_component,
    regexp_matches(p.producto_descripcion_normalizada, c.include_regex, 'i')
        AND NOT regexp_matches(p.producto_descripcion_normalizada, c.exclude_regex, 'i')
        AS semantic_match,
    p.unidad_base = c.target_base_unit
        AND abs(p.cantidad_base / nullif(c.target_quantity_base, 0) - 1) <= 0.02
        AS presentation_match
FROM dim_basket_component AS c
INNER JOIN dim_product_variant_asof AS p
    ON c.build_id = p.build_id
    AND regexp_matches(p.producto_descripcion_normalizada, c.include_regex, 'i')
WHERE NOT regexp_matches(p.producto_descripcion_normalizada, c.exclude_regex, 'i')
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY c.build_id, c.basket_version, c.category_id, p.gtin14
    ORDER BY
        (p.gtin14 = c.gtin14
            AND p.unidad_base = c.target_base_unit
            AND abs(p.cantidad_base / nullif(c.target_quantity_base, 0) - 1) <= 0.02) DESC,
        p.observations DESC,
        p.producto_descripcion_normalizada DESC
) = 1;

CREATE OR REPLACE TABLE bridge_index_common_gtin_daily AS
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
    SELECT
        p.build_id,
        p.scope_version,
        p.snapshot_date,
        p.gtin14,
        COUNT(*) AS observed_banners
    FROM mart_banner_product_daily AS p
    INNER JOIN healthy_scope_day AS d USING (build_id, scope_version, snapshot_date)
    GROUP BY p.build_id, p.scope_version, p.snapshot_date, p.gtin14
)
SELECT g.build_id, g.scope_version, g.snapshot_date, g.gtin14
FROM common_gtin AS g
INNER JOIN scope_size AS s USING (build_id, scope_version)
WHERE g.observed_banners = s.expected_banners;

CREATE OR REPLACE TABLE mart_banner_index_relative_daily AS
WITH benchmark AS (
    SELECT
        p.build_id,
        p.scope_version,
        p.snapshot_date,
        p.gtin14,
        exp(avg(ln(p.banner_price))) AS benchmark_price
    FROM mart_banner_product_daily AS p
    INNER JOIN bridge_index_common_gtin_daily AS g
        USING (build_id, scope_version, snapshot_date, gtin14)
    GROUP BY p.build_id, p.scope_version, p.snapshot_date, p.gtin14
)
SELECT
    p.build_id,
    p.scope_version,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.gtin14,
    p.banner_price,
    b.benchmark_price,
    p.banner_price / nullif(b.benchmark_price, 0) AS price_relative
FROM mart_banner_product_daily AS p
INNER JOIN benchmark AS b
    USING (build_id, scope_version, snapshot_date, gtin14);

CREATE OR REPLACE TABLE mart_banner_index_daily AS
WITH catalog AS (
    SELECT
        build_id, scope_version, snapshot_date, id_comercio, id_bandera,
        COUNT(*) AS catalog_gtins
    FROM mart_banner_product_daily
    GROUP BY build_id, scope_version, snapshot_date, id_comercio, id_bandera
)
SELECT
    r.build_id,
    r.scope_version,
    r.snapshot_date,
    r.id_comercio,
    r.id_bandera,
    100 * exp(avg(ln(r.price_relative))) AS price_index,
    COUNT(*) AS common_gtins,
    c.catalog_gtins,
    100.0 * COUNT(*) / nullif(c.catalog_gtins, 0) AS shared_catalog_pct,
    COUNT(*) >= 500 AS publishable
FROM mart_banner_index_relative_daily AS r
INNER JOIN catalog AS c
    USING (build_id, scope_version, snapshot_date, id_comercio, id_bandera)
GROUP BY
    r.build_id, r.scope_version, r.snapshot_date,
    r.id_comercio, r.id_bandera, c.catalog_gtins;

CREATE OR REPLACE TABLE mart_banner_index_7d AS
SELECT
    build_id,
    scope_version,
    id_comercio,
    id_bandera,
    COUNT(*) AS observed_days,
    100 * exp(avg(ln(price_index / 100))) AS geometric_mean_index,
    min(price_index) AS minimum_index,
    max(price_index) AS maximum_index,
    stddev_samp(price_index) AS index_stddev,
    min(common_gtins) AS minimum_common_gtins,
    bool_and(publishable) AS publishable_all_observed_days
FROM mart_banner_index_daily
GROUP BY build_id, scope_version, id_comercio, id_bandera;

CREATE OR REPLACE TABLE mart_banner_index_driver_daily AS
SELECT
    *,
    100.0 / COUNT(*) OVER (
        PARTITION BY build_id, scope_version, snapshot_date, id_comercio, id_bandera
    ) * ln(price_relative) AS contribution_log_points,
    100 * (price_relative - 1) AS product_relative_pct,
    ROW_NUMBER() OVER (
        PARTITION BY build_id, scope_version, snapshot_date, id_comercio, id_bandera
        ORDER BY abs(ln(price_relative)) DESC, gtin14
    ) AS driver_rank
FROM mart_banner_index_relative_daily;

CREATE OR REPLACE TABLE mart_banner_index_sensitivity_daily AS
SELECT
    build_id,
    scope_version,
    snapshot_date,
    id_comercio,
    id_bandera,
    COUNT(*) AS common_gtins,
    100 * exp(avg(ln(price_relative))) AS raw_index,
    100 * exp(avg(ln(price_relative)) FILTER (WHERE price_relative BETWEEN 0.5 AND 2))
        AS exclude_critical_index,
    100 * exp(avg(ln(greatest(0.5, least(2, price_relative))))) AS winsorized_index,
    COUNT(*) FILTER (WHERE price_relative NOT BETWEEN 0.5 AND 2) AS excluded_products
FROM mart_banner_index_relative_daily
GROUP BY build_id, scope_version, snapshot_date, id_comercio, id_bandera;

CREATE OR REPLACE TABLE mart_banner_pair_overlap_daily AS
WITH catalog AS (
    SELECT
        build_id, scope_version, snapshot_date, id_comercio, id_bandera, gtin14
    FROM mart_banner_product_daily
), pairs AS (
    SELECT
        a.build_id,
        a.scope_version,
        a.snapshot_date,
        a.id_comercio AS comercio_a,
        a.id_bandera AS bandera_a,
        b.id_comercio AS comercio_b,
        b.id_bandera AS bandera_b,
        COUNT(*) AS common_gtins
    FROM catalog AS a
    INNER JOIN catalog AS b
        ON a.build_id = b.build_id
        AND a.scope_version = b.scope_version
        AND a.snapshot_date = b.snapshot_date
        AND a.gtin14 = b.gtin14
        AND concat(a.id_comercio, '|', a.id_bandera)
            < concat(b.id_comercio, '|', b.id_bandera)
    GROUP BY 1,2,3,4,5,6,7
), sizes AS (
    SELECT
        build_id, scope_version, snapshot_date, id_comercio, id_bandera,
        COUNT(*) AS catalog_gtins
    FROM catalog
    GROUP BY 1,2,3,4,5
)
SELECT
    p.*,
    sa.catalog_gtins AS catalog_a,
    sb.catalog_gtins AS catalog_b,
    100.0 * p.common_gtins / least(sa.catalog_gtins, sb.catalog_gtins) AS containment_pct,
    100.0 * p.common_gtins
        / (sa.catalog_gtins + sb.catalog_gtins - p.common_gtins) AS jaccard_pct,
    p.common_gtins >= 500
        AND 100.0 * p.common_gtins / least(sa.catalog_gtins, sb.catalog_gtins) >= 20
        AS publishable
FROM pairs AS p
INNER JOIN sizes AS sa
    ON p.build_id = sa.build_id AND p.scope_version = sa.scope_version
    AND p.snapshot_date = sa.snapshot_date AND p.comercio_a = sa.id_comercio
    AND p.bandera_a = sa.id_bandera
INNER JOIN sizes AS sb
    ON p.build_id = sb.build_id AND p.scope_version = sb.scope_version
    AND p.snapshot_date = sb.snapshot_date AND p.comercio_b = sb.id_comercio
    AND p.bandera_b = sb.id_bandera;

CREATE OR REPLACE TABLE bridge_analysis_product_daily AS
SELECT build_id, snapshot_date, gtin14
FROM bridge_index_common_gtin_daily
UNION
SELECT c.build_id, d.snapshot_date, c.gtin14
FROM dim_basket_component AS c
CROSS JOIN (
    SELECT DISTINCT build_id, snapshot_date FROM dim_store_daily
) AS d
WHERE c.build_id = d.build_id;

CREATE OR REPLACE TABLE fct_analysis_price_store_daily AS
SELECT
    p.build_id,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.id_sucursal,
    s.provincia_codigo,
    p.gtin14,
    p.list_price
FROM fct_global_price_store_daily AS p
INNER JOIN bridge_analysis_product_daily AS a
    USING (build_id, snapshot_date, gtin14)
LEFT JOIN dim_store_daily AS s
    USING (build_id, snapshot_date, id_comercio, id_bandera, id_sucursal);

CREATE OR REPLACE TABLE quality_price_anomaly_daily AS
WITH benchmark AS (
    SELECT
        build_id,
        snapshot_date,
        gtin14,
        median(list_price) AS benchmark_price
    FROM fct_analysis_price_store_daily
    GROUP BY build_id, snapshot_date, gtin14
), cross_section AS (
    SELECT
        p.build_id,
        p.snapshot_date,
        p.id_comercio,
        p.id_bandera,
        p.id_sucursal,
        p.gtin14,
        p.list_price,
        b.benchmark_price,
        p.list_price / nullif(b.benchmark_price, 0) AS price_ratio
    FROM fct_analysis_price_store_daily AS p
    INNER JOIN benchmark AS b USING (build_id, snapshot_date, gtin14)
), lagged AS (
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
    build_id, snapshot_date, id_comercio, id_bandera, id_sucursal, gtin14,
    list_price, benchmark_price, price_ratio,
    CASE WHEN price_ratio NOT BETWEEN 0.5 AND 2 THEN 'CRITICAL' ELSE 'WARNING' END
        AS severity,
    CASE
        WHEN abs(round(log10(price_ratio))) >= 1
            AND abs(log10(price_ratio) - round(log10(price_ratio))) <= log10(1.05)
        THEN 'SCALE_FACTOR'
        ELSE 'CROSS_SECTION_OUTLIER'
    END AS anomaly_type
FROM cross_section
WHERE price_ratio NOT BETWEEN 0.667 AND 1.5
UNION ALL
SELECT
    build_id, snapshot_date, id_comercio, id_bandera, id_sucursal, gtin14,
    list_price, previous_price, list_price / nullif(previous_price, 0),
    CASE
        WHEN list_price / nullif(previous_price, 0) NOT BETWEEN 0.5 AND 2
        THEN 'CRITICAL' ELSE 'WARNING'
    END,
    'TEMPORAL_JUMP'
FROM lagged
WHERE date_diff('day', previous_date, snapshot_date) = 1
    AND previous_price > 0
    AND list_price / previous_price NOT BETWEEN 0.667 AND 1.5;

CREATE OR REPLACE TABLE mart_price_dispersion_daily AS
WITH critical AS (
    SELECT DISTINCT
        build_id, snapshot_date, id_comercio, id_bandera, id_sucursal, gtin14
    FROM quality_price_anomaly_daily
    WHERE severity = 'CRITICAL'
), base AS (
    SELECT
        p.*,
        c.gtin14 IS NOT NULL AS is_critical
    FROM fct_analysis_price_store_daily AS p
    LEFT JOIN critical AS c
        USING (build_id, snapshot_date, id_comercio, id_bandera, id_sucursal, gtin14)
), aggregated AS (
    SELECT
        build_id,
        snapshot_date,
        gtin14,
        CASE
            WHEN grouping(id_comercio) = 1 AND grouping(provincia_codigo) = 1 THEN 'NATIONAL'
            WHEN grouping(id_comercio) = 0 AND grouping(provincia_codigo) = 1 THEN 'BANNER'
            WHEN grouping(id_comercio) = 1 AND grouping(provincia_codigo) = 0 THEN 'PROVINCE'
            ELSE 'BANNER_PROVINCE'
        END AS dispersion_level,
        id_comercio,
        id_bandera,
        provincia_codigo,
        COUNT(*) AS stores_raw,
        COUNT(*) FILTER (WHERE NOT is_critical) AS stores_clean,
        COUNT(DISTINCT concat_ws('|', id_comercio, id_bandera)) AS banners,
        median(list_price) AS price_median_raw,
        quantile_cont(list_price, 0.10) AS price_p10_raw,
        quantile_cont(list_price, 0.90) AS price_p90_raw,
        median(list_price) FILTER (WHERE NOT is_critical) AS price_median_clean,
        quantile_cont(list_price, 0.10) FILTER (WHERE NOT is_critical) AS price_p10_clean,
        quantile_cont(list_price, 0.90) FILTER (WHERE NOT is_critical) AS price_p90_clean,
        COUNT(*) FILTER (WHERE is_critical) AS excluded_critical
    FROM base
    GROUP BY GROUPING SETS (
        (build_id, snapshot_date, gtin14),
        (build_id, snapshot_date, gtin14, id_comercio, id_bandera),
        (build_id, snapshot_date, gtin14, provincia_codigo),
        (build_id, snapshot_date, gtin14, id_comercio, id_bandera, provincia_codigo)
    )
)
SELECT
    *,
    (price_p90_raw - price_p10_raw) / nullif(price_median_raw, 0) AS dispersion_raw,
    (price_p90_clean - price_p10_clean) / nullif(price_median_clean, 0) AS dispersion_clean,
    CASE
        WHEN dispersion_level IN ('PROVINCE', 'BANNER_PROVINCE')
            AND (provincia_codigo IS NULL OR provincia_codigo NOT LIKE 'AR-%')
            THEN 'INVALID_GEOGRAPHY'
        WHEN dispersion_level = 'NATIONAL' AND stores_clean >= 20 AND banners >= 3
            THEN 'PUBLISHABLE'
        WHEN dispersion_level = 'PROVINCE' AND stores_clean >= 20 AND banners >= 3
            THEN 'PUBLISHABLE'
        WHEN dispersion_level IN ('BANNER', 'BANNER_PROVINCE') AND stores_clean >= 20
            THEN 'PUBLISHABLE'
        WHEN stores_clean >= 10 THEN 'DIRECTIONAL'
        ELSE 'SUPPRESSED'
    END AS coverage_status
FROM aggregated;

CREATE OR REPLACE TABLE mart_dispersion_entity_daily AS
SELECT
    build_id,
    snapshot_date,
    dispersion_level,
    id_comercio,
    id_bandera,
    provincia_codigo,
    COUNT(*) FILTER (WHERE coverage_status = 'PUBLISHABLE') AS publishable_products,
    median(dispersion_raw) FILTER (WHERE coverage_status = 'PUBLISHABLE')
        AS median_dispersion_raw,
    median(dispersion_clean) FILTER (WHERE coverage_status = 'PUBLISHABLE')
        AS median_dispersion_clean,
    sum(excluded_critical) AS excluded_critical_prices,
    CASE
        WHEN dispersion_level IN ('PROVINCE', 'BANNER_PROVINCE')
            AND (provincia_codigo IS NULL OR provincia_codigo NOT LIKE 'AR-%')
        THEN 'INVALID_GEOGRAPHY'
        WHEN COUNT(*) FILTER (WHERE coverage_status = 'PUBLISHABLE') >= 100
        THEN 'PUBLISHABLE'
        WHEN COUNT(*) FILTER (
            WHERE coverage_status IN ('PUBLISHABLE', 'DIRECTIONAL')
        ) >= 30
        THEN 'DIRECTIONAL'
        ELSE 'SUPPRESSED'
    END AS coverage_status
FROM mart_price_dispersion_daily
GROUP BY
    build_id, snapshot_date, dispersion_level,
    id_comercio, id_bandera, provincia_codigo;

CREATE OR REPLACE TABLE mart_basket_component_store_daily AS
SELECT
    p.build_id,
    c.basket_version,
    p.snapshot_date,
    p.id_comercio,
    p.id_bandera,
    p.id_sucursal,
    p.provincia_codigo,
    c.category_id,
    c.category_name,
    c.gtin14,
    p.list_price AS component_cost
FROM fct_analysis_price_store_daily AS p
INNER JOIN dim_basket_component AS c USING (build_id, gtin14)
INNER JOIN dim_basket_version AS v
    ON c.build_id = v.build_id AND c.basket_version = v.basket_version
    AND p.snapshot_date >= v.valid_from
    AND (v.valid_to IS NULL OR p.snapshot_date <= v.valid_to)
    AND v.status = 'PUBLISHED'
;

CREATE OR REPLACE TABLE mart_basket_store_daily AS
WITH active_stores AS (
    SELECT DISTINCT
        build_id, snapshot_date, id_comercio, id_bandera, id_sucursal
    FROM fct_global_price_store_daily
), expected AS (
    SELECT build_id, basket_version, COUNT(*) AS expected_components
    FROM dim_basket_component
    GROUP BY build_id, basket_version
)
SELECT
    a.build_id,
    e.basket_version,
    a.snapshot_date,
    a.id_comercio,
    a.id_bandera,
    a.id_sucursal,
    s.provincia_codigo,
    sum(c.component_cost) AS observed_cost,
    COUNT(c.category_id) AS found_components,
    e.expected_components,
    COUNT(c.category_id)::DOUBLE / e.expected_components AS basket_coverage,
    COUNT(c.category_id) = e.expected_components AS complete_basket
FROM active_stores AS a
INNER JOIN expected AS e USING (build_id)
LEFT JOIN mart_basket_component_store_daily AS c
    ON a.build_id = c.build_id AND e.basket_version = c.basket_version
    AND a.snapshot_date = c.snapshot_date AND a.id_comercio = c.id_comercio
    AND a.id_bandera = c.id_bandera AND a.id_sucursal = c.id_sucursal
LEFT JOIN dim_store_daily AS s
    ON a.build_id = s.build_id AND a.snapshot_date = s.snapshot_date
    AND a.id_comercio = s.id_comercio AND a.id_bandera = s.id_bandera
    AND a.id_sucursal = s.id_sucursal
GROUP BY
    a.build_id, e.basket_version, a.snapshot_date, a.id_comercio,
    a.id_bandera, a.id_sucursal, s.provincia_codigo, e.expected_components;

CREATE OR REPLACE TABLE mart_basket_banner_daily AS
SELECT
    build_id,
    basket_version,
    snapshot_date,
    id_comercio,
    id_bandera,
    COUNT(*) AS active_stores,
    COUNT(*) FILTER (WHERE complete_basket) AS complete_stores,
    COUNT(*) FILTER (WHERE complete_basket)::DOUBLE / COUNT(*) AS completion_rate,
    avg(observed_cost) FILTER (WHERE complete_basket) AS branch_mean_cost,
    median(observed_cost) FILTER (WHERE complete_basket) AS branch_median_cost,
    quantile_cont(observed_cost, 0.10) FILTER (WHERE complete_basket) AS cost_p10,
    quantile_cont(observed_cost, 0.90) FILTER (WHERE complete_basket) AS cost_p90,
    CASE WHEN COUNT(*) FILTER (WHERE complete_basket) >= 20
        THEN 'PUBLISHABLE'
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 5 THEN 'DIRECTIONAL'
        ELSE 'SUPPRESSED' END AS coverage_status
FROM mart_basket_store_daily
GROUP BY build_id, basket_version, snapshot_date, id_comercio, id_bandera;

CREATE OR REPLACE TABLE mart_basket_province_daily AS
SELECT
    build_id,
    basket_version,
    snapshot_date,
    provincia_codigo,
    COUNT(*) AS active_stores,
    COUNT(*) FILTER (WHERE complete_basket) AS complete_stores,
    COUNT(DISTINCT concat_ws('|', id_comercio, id_bandera))
        FILTER (WHERE complete_basket) AS complete_banners,
    COUNT(*) FILTER (WHERE complete_basket)::DOUBLE / COUNT(*) AS completion_rate,
    avg(observed_cost) FILTER (WHERE complete_basket) AS branch_mean_cost,
    median(observed_cost) FILTER (WHERE complete_basket) AS branch_median_cost,
    quantile_cont(observed_cost, 0.10) FILTER (WHERE complete_basket) AS cost_p10,
    quantile_cont(observed_cost, 0.90) FILTER (WHERE complete_basket) AS cost_p90,
    CASE
        WHEN provincia_codigo IS NULL OR provincia_codigo NOT LIKE 'AR-%'
            THEN 'INVALID_GEOGRAPHY'
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 20
            AND COUNT(DISTINCT concat_ws('|', id_comercio, id_bandera))
                FILTER (WHERE complete_basket) >= 3 THEN 'PUBLISHABLE'
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 5
            AND COUNT(DISTINCT concat_ws('|', id_comercio, id_bandera))
                FILTER (WHERE complete_basket) >= 2 THEN 'DIRECTIONAL'
        ELSE 'SUPPRESSED'
    END AS coverage_status
FROM mart_basket_store_daily
GROUP BY build_id, basket_version, snapshot_date, provincia_codigo;

CREATE OR REPLACE TABLE mart_basket_banner_province_daily AS
SELECT
    build_id,
    basket_version,
    snapshot_date,
    id_comercio,
    id_bandera,
    provincia_codigo,
    COUNT(*) AS active_stores,
    COUNT(*) FILTER (WHERE complete_basket) AS complete_stores,
    median(observed_cost) FILTER (WHERE complete_basket) AS branch_median_cost,
    CASE
        WHEN provincia_codigo IS NULL OR provincia_codigo NOT LIKE 'AR-%'
            THEN 'INVALID_GEOGRAPHY'
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 20 THEN 'PUBLISHABLE'
        WHEN COUNT(*) FILTER (WHERE complete_basket) >= 5 THEN 'DIRECTIONAL'
        ELSE 'SUPPRESSED' END AS coverage_status
FROM mart_basket_store_daily
GROUP BY
    build_id, basket_version, snapshot_date, id_comercio,
    id_bandera, provincia_codigo;

CREATE OR REPLACE TABLE mart_basket_national_daily AS
SELECT
    build_id,
    basket_version,
    snapshot_date,
    COUNT(*) FILTER (WHERE complete_basket AND provincia_codigo LIKE 'AR-%')
        AS complete_stores,
    COUNT(DISTINCT provincia_codigo)
        FILTER (WHERE complete_basket AND provincia_codigo LIKE 'AR-%')
        AS represented_provinces,
    avg(observed_cost)
        FILTER (WHERE complete_basket AND provincia_codigo LIKE 'AR-%')
        AS network_branch_mean,
    median(observed_cost)
        FILTER (WHERE complete_basket AND provincia_codigo LIKE 'AR-%')
        AS network_branch_median,
    'OBSERVED_NETWORK_NOT_POPULATION_WEIGHTED' AS estimation_type
FROM mart_basket_store_daily
GROUP BY build_id, basket_version, snapshot_date;

CREATE OR REPLACE TABLE mart_basket_savings_daily AS
WITH banner AS (
    SELECT
        build_id, basket_version, snapshot_date, 'BANNER' AS comparison_level,
        max(branch_median_cost) AS highest_cost,
        min(branch_median_cost) AS lowest_cost
    FROM mart_basket_banner_daily
    WHERE coverage_status = 'PUBLISHABLE'
    GROUP BY build_id, basket_version, snapshot_date
), province AS (
    SELECT
        build_id, basket_version, snapshot_date, 'PROVINCE' AS comparison_level,
        max(branch_median_cost) AS highest_cost,
        min(branch_median_cost) AS lowest_cost
    FROM mart_basket_province_daily
    WHERE coverage_status = 'PUBLISHABLE'
    GROUP BY build_id, basket_version, snapshot_date
)
SELECT
    *,
    highest_cost - lowest_cost AS potential_saving_amount,
    100 * (highest_cost - lowest_cost) / nullif(highest_cost, 0)
        AS potential_saving_pct
FROM (
    SELECT * FROM banner
    UNION ALL
    SELECT * FROM province
);
