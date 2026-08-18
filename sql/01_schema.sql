CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id UUID PRIMARY KEY,
    parent_run_id UUID,
    stage VARCHAR NOT NULL,
    snapshot_date DATE,
    as_of_date DATE,
    build_id UUID,
    status VARCHAR NOT NULL,
    force BOOLEAN NOT NULL DEFAULT false,
    source_sha256 VARCHAR,
    source_set_hash VARCHAR,
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ,
    warning_count BIGINT NOT NULL DEFAULT 0,
    error_count BIGINT NOT NULL DEFAULT 0,
    details VARCHAR
);

CREATE TABLE IF NOT EXISTS snapshot_state (
    snapshot_date DATE PRIMARY KEY,
    active_ingest_run_id UUID NOT NULL,
    raw_sha256 VARCHAR NOT NULL,
    source_path VARCHAR NOT NULL,
    source_bytes BIGINT NOT NULL,
    package_count INTEGER NOT NULL,
    warning_count BIGINT NOT NULL,
    activated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS ingestion_log (
    ingest_run_id UUID NOT NULL,
    snapshot_date DATE NOT NULL,
    source_package VARCHAR NOT NULL,
    file_name VARCHAR NOT NULL,
    source_rows BIGINT,
    loaded_rows BIGINT,
    footer_rows BIGINT NOT NULL DEFAULT 0,
    null_bytes_removed BIGINT NOT NULL DEFAULT 0,
    reconstructed_lines BIGINT NOT NULL DEFAULT 0,
    status VARCHAR NOT NULL,
    details VARCHAR,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS commerce_snapshot (
    ingest_run_id UUID NOT NULL,
    snapshot_date DATE NOT NULL,
    source_package VARCHAR NOT NULL,
    id_comercio VARCHAR,
    id_bandera VARCHAR,
    comercio_cuit VARCHAR,
    comercio_razon_social VARCHAR,
    comercio_bandera_nombre VARCHAR,
    comercio_bandera_url VARCHAR,
    comercio_ultima_actualizacion TIMESTAMPTZ,
    comercio_version_sepa VARCHAR
);

CREATE TABLE IF NOT EXISTS store_snapshot (
    ingest_run_id UUID NOT NULL,
    snapshot_date DATE NOT NULL,
    source_package VARCHAR NOT NULL,
    id_comercio VARCHAR,
    id_bandera VARCHAR,
    id_sucursal VARCHAR,
    sucursal_nombre VARCHAR,
    sucursal_tipo VARCHAR,
    calle VARCHAR,
    numero VARCHAR,
    latitud DOUBLE,
    longitud DOUBLE,
    observaciones VARCHAR,
    barrio VARCHAR,
    codigo_postal VARCHAR,
    localidad VARCHAR,
    provincia_codigo VARCHAR,
    lunes_horario VARCHAR,
    martes_horario VARCHAR,
    miercoles_horario VARCHAR,
    jueves_horario VARCHAR,
    viernes_horario VARCHAR,
    sabado_horario VARCHAR,
    domingo_horario VARCHAR,
    coordenadas_validas BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS fact_price (
    ingest_run_id UUID NOT NULL,
    snapshot_date DATE NOT NULL,
    source_package VARCHAR NOT NULL,
    id_comercio VARCHAR,
    id_bandera VARCHAR,
    id_sucursal VARCHAR,
    id_producto VARCHAR,
    productos_ean BOOLEAN NOT NULL,
    gtin14 VARCHAR,
    gtin_valido BOOLEAN NOT NULL,
    product_code_scope VARCHAR NOT NULL,
    producto_descripcion VARCHAR,
    producto_descripcion_normalizada VARCHAR,
    cantidad_presentacion DOUBLE,
    unidad_presentacion VARCHAR,
    marca VARCHAR,
    precio_lista DECIMAL(18, 4),
    precio_referencia DECIMAL(18, 4),
    cantidad_referencia DOUBLE,
    unidad_referencia VARCHAR,
    precio_promo_general DECIMAL(18, 4),
    leyenda_promo_general VARCHAR,
    precio_promo_segmentada DECIMAL(18, 4),
    leyenda_promo_segmentada VARCHAR,
    precio_lista_valido BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS build_inputs (
    build_id UUID NOT NULL,
    snapshot_date DATE NOT NULL,
    ingest_run_id UUID NOT NULL,
    raw_sha256 VARCHAR NOT NULL,
    PRIMARY KEY (build_id, snapshot_date)
);

CREATE TABLE IF NOT EXISTS warehouse_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
    published_build_id UUID NOT NULL,
    as_of_date DATE NOT NULL,
    window_start DATE NOT NULL,
    source_set_hash VARCHAR NOT NULL,
    schema_version VARCHAR NOT NULL,
    published_at TIMESTAMPTZ NOT NULL
);

CREATE OR REPLACE MACRO normalize_gtin14(product_id, is_ean) AS (
    CASE
        WHEN lower(trim(is_ean)) IN ('1', 'true', 't', 'si', 'sí')
            AND regexp_full_match(trim(product_id), '([0-9]{8}|[0-9]{12}|[0-9]{13}|[0-9]{14})')
        THEN lpad(trim(product_id), 14, '0')
        ELSE NULL
    END
);

CREATE OR REPLACE MACRO is_valid_gtin14(code) AS (
    code IS NOT NULL
    AND regexp_full_match(code, '[0-9]{14}')
    AND CAST(substr(code, 14, 1) AS INTEGER) = (
        10 - (
            CAST(substr(code, 1, 1) AS INTEGER) * 3
            + CAST(substr(code, 2, 1) AS INTEGER)
            + CAST(substr(code, 3, 1) AS INTEGER) * 3
            + CAST(substr(code, 4, 1) AS INTEGER)
            + CAST(substr(code, 5, 1) AS INTEGER) * 3
            + CAST(substr(code, 6, 1) AS INTEGER)
            + CAST(substr(code, 7, 1) AS INTEGER) * 3
            + CAST(substr(code, 8, 1) AS INTEGER)
            + CAST(substr(code, 9, 1) AS INTEGER) * 3
            + CAST(substr(code, 10, 1) AS INTEGER)
            + CAST(substr(code, 11, 1) AS INTEGER) * 3
            + CAST(substr(code, 12, 1) AS INTEGER)
            + CAST(substr(code, 13, 1) AS INTEGER) * 3
        ) % 10
    ) % 10
);

CREATE OR REPLACE MACRO classify_product_code(product_id, is_ean, valid_gtin) AS (
    CASE
        WHEN regexp_full_match(trim(product_id), '(2[0-9]{7}|02[0-9]{10}|2[0-9]{12}|02[0-9]{12})')
            THEN 'RESTRICTED_LOCAL'
        WHEN NOT coalesce(is_ean, false) THEN 'INTERNAL_LOCAL'
        WHEN coalesce(valid_gtin, false) THEN 'GLOBAL_GTIN'
        ELSE 'INVALID'
    END
);

CREATE OR REPLACE MACRO normalize_unit(unit_name) AS (
    CASE upper(trim(unit_name))
        WHEN 'G' THEN 'G' WHEN 'GR' THEN 'G' WHEN 'GR.' THEN 'G'
        WHEN 'GRM' THEN 'G' WHEN 'GRS' THEN 'G' WHEN 'GRAMOS' THEN 'G'
        WHEN 'KG' THEN 'KG' WHEN 'KGS' THEN 'KG' WHEN 'KGM' THEN 'KG'
        WHEN 'KGR' THEN 'KG' WHEN 'KG.' THEN 'KG' WHEN 'KILO' THEN 'KG'
        WHEN 'KILOGRAMOS' THEN 'KG'
        WHEN 'L' THEN 'L' WHEN 'LT' THEN 'L' WHEN 'LT.' THEN 'L'
        WHEN 'LTR' THEN 'L' WHEN 'LTS' THEN 'L' WHEN 'LITRO' THEN 'L'
        WHEN 'LITROS' THEN 'L'
        WHEN 'ML' THEN 'ML' WHEN 'ML.' THEN 'ML' WHEN 'CC' THEN 'ML'
        WHEN 'CC.' THEN 'ML' WHEN 'CM3' THEN 'ML'
        WHEN 'UN' THEN 'UN' WHEN 'UN.' THEN 'UN' WHEN 'UNI' THEN 'UN'
        WHEN 'UNIDAD' THEN 'UN' WHEN 'UNIDADES' THEN 'UN' WHEN 'EA' THEN 'UN'
        ELSE upper(nullif(trim(unit_name), ''))
    END
);
