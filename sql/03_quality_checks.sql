CREATE OR REPLACE TABLE quality_checks AS
WITH context AS (
    SELECT * FROM build_context
), input_quality AS (
    SELECT
        i.build_id,
        COUNT(*) AS input_dates,
        min(i.snapshot_date) AS date_min,
        max(i.snapshot_date) AS date_max
    FROM build_inputs AS i
    INNER JOIN context AS c ON i.build_id = c.build_id
    GROUP BY i.build_id
), ingestion_quality AS (
    SELECT
        i.build_id,
        coalesce(sum(abs(coalesce(l.source_rows, 0) - coalesce(l.loaded_rows, 0))), 0)
            AS row_difference,
        COUNT(*) FILTER (WHERE l.status NOT IN ('success', 'source_empty'))
            AS structural_failures,
        COUNT(*) FILTER (WHERE l.status = 'source_empty') AS empty_source_packages,
        coalesce(sum(l.reconstructed_lines), 0) AS reconstructed_source_lines
    FROM build_inputs AS i
    LEFT JOIN ingestion_log AS l ON i.ingest_run_id = l.ingest_run_id
    INNER JOIN context AS c ON i.build_id = c.build_id
    GROUP BY i.build_id
), index_center AS (
    SELECT
        build_id,
        coalesce(sum(CASE WHEN abs(center_value - 100) > 0.0001 THEN 1 ELSE 0 END), 0)
            AS failed_days
    FROM (
        SELECT
            build_id,
            snapshot_date,
            100 * exp(avg(ln(price_index / 100))) AS center_value
        FROM mart_banner_index_daily
        GROUP BY build_id, snapshot_date
    )
    GROUP BY build_id
), index_panel AS (
    SELECT
        build_id,
        coalesce(sum(CASE WHEN chain_min <> chain_max THEN 1 ELSE 0 END), 0)
            AS inconsistent_panels
    FROM (
        SELECT
            build_id,
            snapshot_date,
            min(common_gtins) AS chain_min,
            max(common_gtins) AS chain_max
        FROM mart_banner_index_daily
        GROUP BY build_id, snapshot_date
    )
    GROUP BY build_id
)
SELECT c.build_id, 'build_input_count' AS test_name,
       abs(7 - q.input_dates) AS failed_rows, 'high' AS severity,
       'El build exige siete snapshots consecutivos.' AS details
FROM context AS c INNER JOIN input_quality AS q USING (build_id)
UNION ALL
SELECT c.build_id, 'build_input_boundaries',
       CASE WHEN q.date_min = c.window_start AND q.date_max = c.as_of_date THEN 0 ELSE 1 END,
       'high', 'Los limites deben coincidir con window_start y as_of.'
FROM context AS c INNER JOIN input_quality AS q USING (build_id)
UNION ALL
SELECT c.build_id, 'source_loaded_row_difference', q.row_difference,
       'high', 'Toda fila estructuralmente valida debe cargarse.'
FROM context AS c INNER JOIN ingestion_quality AS q USING (build_id)
UNION ALL
SELECT c.build_id, 'ingestion_structural_status', q.structural_failures,
       'high', 'No se permiten archivos faltantes, malformados o con parsing parcial.'
FROM context AS c INNER JOIN ingestion_quality AS q USING (build_id)
UNION ALL
SELECT c.build_id, 'comparable_key_null',
       COUNT(*) FILTER (
           WHERE p.build_id IS NOT NULL
             AND (p.id_comercio IS NULL OR p.id_bandera IS NULL
               OR p.id_sucursal IS NULL OR p.gtin14 IS NULL)
       ), 'high',
       'El hecho global comparable requiere claves completas.'
FROM context AS c
LEFT JOIN fct_global_price_store_daily AS p USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'restricted_code_in_global_fact',
       COUNT(*) FILTER (
           WHERE g.build_id IS NOT NULL AND g.product_code_scope <> 'GLOBAL_GTIN'
       ), 'high',
       'Los codigos restringidos 20-29 no pueden entrar al hecho global.'
FROM context AS c
LEFT JOIN fct_global_price_store_daily AS g USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'daily_mart_date_count',
       abs(7 - COUNT(DISTINCT p.snapshot_date)), 'high',
       'mart_price_product_daily debe conservar las siete fechas.'
FROM context AS c LEFT JOIN mart_price_product_daily AS p USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'basket_component_count',
       abs(8 - COUNT(*)), 'high', 'La version publicada contiene ocho componentes fijos.'
FROM context AS c LEFT JOIN dim_basket_component AS b USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'basket_component_uniqueness',
       (COUNT(*) - COUNT(DISTINCT b.category_id))
       + (COUNT(*) - COUNT(DISTINCT b.gtin14)),
       'high', 'Categorias y GTIN deben ser unicos dentro de la canasta.'
FROM context AS c LEFT JOIN dim_basket_component AS b USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'basket_selected_semantic_or_presentation_mismatch',
       COUNT(*) FILTER (WHERE r.gtin14 IS NULL OR NOT coalesce(r.semantic_match, false)
           OR NOT coalesce(r.presentation_match, false)),
       'high', 'Cada componente fijo debe respetar semantica y presentacion objetivo.'
FROM context AS c
INNER JOIN dim_basket_component AS b USING (build_id)
LEFT JOIN mart_basket_candidate_review AS r
    ON b.build_id = r.build_id AND b.basket_version = r.basket_version
    AND b.category_id = r.category_id AND r.selected_component
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'hileret_light_selected',
       COUNT(*) FILTER (
           WHERE regexp_matches(b.canonical_product_name, 'HILERET.*LIGHT', 'i')
       ), 'high',
       'Hileret Light no representa azucar blanca comun.'
FROM context AS c
LEFT JOIN dim_basket_component AS b USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'index_common_panel_consistency', coalesce(p.inconsistent_panels, 0),
       'high', 'Todas las cadenas deben usar el mismo numero de GTIN por dia.'
FROM context AS c LEFT JOIN index_panel AS p USING (build_id)
UNION ALL
SELECT c.build_id, 'index_geometric_center', coalesce(p.failed_days, 0),
       'high', 'La media geometrica de indices por dia debe ser 100.'
FROM context AS c LEFT JOIN index_center AS p USING (build_id)
UNION ALL
SELECT c.build_id, 'index_output_nonempty',
       CASE WHEN COUNT(i.build_id) = 0 THEN 1 ELSE 0 END,
       'high', 'El build debe producir filas del indice comun.'
FROM context AS c
LEFT JOIN mart_banner_index_daily AS i USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'published_invalid_geography',
       (
           SELECT COUNT(*)
           FROM (
               SELECT provincia_codigo
               FROM mart_dispersion_entity_daily AS d
               WHERE d.build_id = c.build_id
                 AND d.dispersion_level IN ('PROVINCE', 'BANNER_PROVINCE')
                 AND d.coverage_status = 'PUBLISHABLE'
                 AND (d.provincia_codigo IS NULL OR d.provincia_codigo NOT LIKE 'AR-%')
               UNION ALL
               SELECT provincia_codigo
               FROM mart_basket_province_daily AS p
               WHERE p.build_id = c.build_id
                 AND p.coverage_status = 'PUBLISHABLE'
                 AND (p.provincia_codigo IS NULL OR p.provincia_codigo NOT LIKE 'AR-%')
               UNION ALL
               SELECT provincia_codigo
               FROM mart_basket_banner_province_daily AS bp
               WHERE bp.build_id = c.build_id
                 AND bp.coverage_status = 'PUBLISHABLE'
                 AND (bp.provincia_codigo IS NULL OR bp.provincia_codigo NOT LIKE 'AR-%')
           ) AS invalid_published
       ),
       'high', 'La geografia invalida no puede publicarse ni entrar a rankings.'
FROM context AS c
UNION ALL
SELECT c.build_id, 'known_empty_source_packages', q.empty_source_packages,
       'medium', 'Paquetes vacios conocidos reducen cobertura aunque no rompen parsing.'
FROM context AS c INNER JOIN ingestion_quality AS q USING (build_id)
UNION ALL
SELECT c.build_id, 'reconstructed_source_lines', q.reconstructed_source_lines,
       'medium', 'Continuaciones fisicas se unieron y luego validaron contra el esquema.'
FROM context AS c INNER JOIN ingestion_quality AS q USING (build_id)
UNION ALL
SELECT c.build_id, 'unhealthy_snapshot_days', COUNT(*) FILTER (WHERE NOT h.source_healthy),
       'medium', 'Dias debajo de 80% de filas o sucursales de la mediana semanal.'
FROM context AS c LEFT JOIN mart_snapshot_health AS h USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'unhealthy_scope_banner_days', COUNT(*) FILTER (WHERE NOT h.source_healthy),
       'medium', 'Cadena-dia debajo de 80% de su cobertura semanal.'
FROM context AS c LEFT JOIN mart_banner_day_health AS h USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'invalid_source_product_codes', sum(q.invalid_code_rows),
       'medium', 'EAN declarados que no superan formato o digito verificador.'
FROM context AS c LEFT JOIN mart_quality_daily AS q USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'invalid_list_prices', sum(q.invalid_list_price_rows),
       'medium', 'Precios nulos, no numericos, cero o negativos.'
FROM context AS c LEFT JOIN mart_quality_daily AS q USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'source_null_keys', sum(q.null_key_rows),
       'medium', 'Filas fuente sin alguna clave obligatoria; quedan fuera de comparables.'
FROM context AS c LEFT JOIN mart_quality_daily AS q USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'critical_price_anomalies',
       COUNT(*) FILTER (WHERE a.severity = 'CRITICAL'),
       'medium', 'Saltos de escala o precios fuera de un factor 0.5-2.'
FROM context AS c LEFT JOIN quality_price_anomaly_daily AS a USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'invalid_or_missing_geography',
       COUNT(*) FILTER (
           WHERE s.build_id IS NOT NULL
             AND (s.provincia_codigo IS NULL OR s.provincia_codigo NOT LIKE 'AR-%')
       ),
       'medium', 'Sucursales sin codigo provincial AR-* normalizado.'
FROM context AS c LEFT JOIN dim_store_daily AS s USING (build_id)
GROUP BY c.build_id
UNION ALL
SELECT c.build_id, 'stale_as_of_date',
       CASE WHEN date_diff('day', c.as_of_date, c.validation_date) > 14 THEN 1 ELSE 0 END,
       'medium', 'El corte publicado tiene mas de 14 dias de antiguedad.'
FROM context AS c;
