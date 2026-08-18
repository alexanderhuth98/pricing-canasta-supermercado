import hashlib
import re
from contextlib import suppress
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from time import perf_counter
from uuid import UUID, uuid4

import duckdb

from .config import DATABASE_PATH, SCHEMA_VERSION, SQL_DIR, WINDOW_DAYS
from .ingest import connect

REQUIRED_BUILD_TABLES = (
    "dim_banner_daily",
    "dim_store_daily",
    "dim_product_variant_asof",
    "dim_product_asof",
    "fct_global_price_store_daily",
    "fct_local_price_store_daily",
    "mart_price_product_daily",
    "mart_banner_day_health",
    "mart_product_persistence_7d",
    "mart_banner_index_daily",
    "mart_banner_index_driver_daily",
    "mart_banner_index_sensitivity_daily",
    "mart_price_dispersion_daily",
    "mart_dispersion_entity_daily",
    "mart_basket_store_daily",
    "mart_basket_province_daily",
    "mart_basket_national_daily",
    "mart_basket_savings_daily",
    "quality_checks",
)

NONEMPTY_BUILD_TABLES = {
    "dim_banner_daily",
    "dim_store_daily",
    "dim_product_variant_asof",
    "dim_product_asof",
    "fct_global_price_store_daily",
    "mart_price_product_daily",
    "mart_banner_day_health",
    "mart_banner_index_daily",
    "mart_price_dispersion_daily",
    "mart_dispersion_entity_daily",
    "mart_basket_store_daily",
    "mart_basket_province_daily",
    "mart_basket_national_daily",
    "quality_checks",
}

EXPECTED_QUALITY_CHECKS = {
    "basket_component_count",
    "basket_component_uniqueness",
    "basket_selected_semantic_or_presentation_mismatch",
    "build_input_boundaries",
    "build_input_count",
    "comparable_key_null",
    "critical_price_anomalies",
    "daily_mart_date_count",
    "hileret_light_selected",
    "index_common_panel_consistency",
    "index_geometric_center",
    "index_output_nonempty",
    "ingestion_structural_status",
    "invalid_list_prices",
    "invalid_or_missing_geography",
    "invalid_source_product_codes",
    "known_empty_source_packages",
    "published_invalid_geography",
    "reconstructed_source_lines",
    "restricted_code_in_global_fact",
    "source_loaded_row_difference",
    "source_null_keys",
    "stale_as_of_date",
    "unhealthy_scope_banner_days",
    "unhealthy_snapshot_days",
}


def _split_sql(script: str) -> list[str]:
    return [statement.strip() for statement in script.split(";\n") if statement.strip()]


def _statement_label(statement: str) -> str:
    match = re.search(
        r"(?:CREATE\s+OR\s+REPLACE|CREATE)\s+TABLE\s+([a-zA-Z0-9_]+)",
        statement,
        flags=re.IGNORECASE,
    )
    return match.group(1) if match else "sentencia SQL"


def _resolve_inputs(
    connection: duckdb.DuckDBPyConnection, as_of: date | None
) -> tuple[date, date, list[tuple]]:
    if as_of is None:
        row = connection.execute("SELECT max(snapshot_date) FROM snapshot_state").fetchone()
        if not row or row[0] is None:
            raise RuntimeError("No existen snapshots ingeridos con exito.")
        as_of = row[0]
    window_start = as_of - timedelta(days=WINDOW_DAYS - 1)
    rows = connection.execute(
        """
        SELECT snapshot_date, active_ingest_run_id, raw_sha256
        FROM snapshot_state
        WHERE snapshot_date BETWEEN ? AND ?
        ORDER BY snapshot_date
        """,
        [window_start, as_of],
    ).fetchall()
    expected_dates = [window_start + timedelta(days=offset) for offset in range(WINDOW_DAYS)]
    actual_dates = [row[0] for row in rows]
    if actual_dates != expected_dates:
        raise RuntimeError(
            f"La ventana debe contener {WINDOW_DAYS} fechas consecutivas. "
            f"Esperadas={expected_dates}; disponibles={actual_dates}."
        )
    return as_of, window_start, rows


def _source_set_hash(rows: list[tuple]) -> str:
    serialized = "\n".join(f"{row[0]}|{row[1]}|{row[2]}" for row in rows)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def _verify_lineage(connection: duckdb.DuckDBPyConnection, build_id: UUID) -> None:
    existing = {row[0] for row in connection.execute("SHOW TABLES").fetchall()}
    missing = [table for table in REQUIRED_BUILD_TABLES if table not in existing]
    if missing:
        raise RuntimeError(f"El build no creo tablas requeridas: {missing}")
    for table in REQUIRED_BUILD_TABLES:
        row_count, minimum_id, maximum_id = connection.execute(
            f"SELECT COUNT(*), min(build_id), max(build_id) FROM {table}"
        ).fetchone()
        if row_count == 0:
            if table in NONEMPTY_BUILD_TABLES:
                raise RuntimeError(f"El build dejo vacia la tabla requerida {table}.")
            continue
        if minimum_id != build_id or maximum_id != build_id:
            raise RuntimeError(
                f"Linaje invalido en {table}: build_ids={(minimum_id, maximum_id)}."
            )


def _verify_quality_check_inventory(
    connection: duckdb.DuckDBPyConnection, build_id: UUID
) -> None:
    actual = {
        row[0]
        for row in connection.execute(
            "SELECT test_name FROM quality_checks WHERE build_id = ?",
            [str(build_id)],
        ).fetchall()
    }
    if actual != EXPECTED_QUALITY_CHECKS:
        missing = sorted(EXPECTED_QUALITY_CHECKS - actual)
        extra = sorted(actual - EXPECTED_QUALITY_CHECKS)
        raise RuntimeError(
            f"Inventario de quality checks invalido: faltantes={missing}; extras={extra}."
        )


def _verify_global_grain(connection: duckdb.DuckDBPyConnection, build_id: UUID) -> None:
    duplicate = connection.execute(
        """
        SELECT p.snapshot_date, p.id_comercio, p.id_bandera, p.id_sucursal,
               p.gtin14, COUNT(*) AS duplicate_rows
        FROM fact_price AS p
        INNER JOIN build_inputs AS i
            ON p.ingest_run_id = i.ingest_run_id AND p.snapshot_date = i.snapshot_date
        WHERE i.build_id = ?
            AND p.product_code_scope = 'GLOBAL_GTIN'
            AND p.precio_lista_valido
            AND p.id_comercio IS NOT NULL
            AND p.id_bandera IS NOT NULL
            AND p.id_sucursal IS NOT NULL
        GROUP BY
            p.snapshot_date, p.id_comercio, p.id_bandera, p.id_sucursal, p.gtin14
        HAVING COUNT(*) > 1
        LIMIT 1
        """,
        [str(build_id)],
    ).fetchone()
    if duplicate:
        raise RuntimeError(f"Grano global duplicado; no se puede proyectar: {duplicate}.")


def build_analytics(
    as_of: date | None = None,
    database_path: Path = DATABASE_PATH,
    failure_after_table: str | None = None,
    reference_date: date | None = None,
) -> UUID:
    connection = connect(database_path=database_path)
    try:
        connection.execute(
            """
            UPDATE pipeline_runs
            SET status = 'interrupted', finished_at = CURRENT_TIMESTAMP,
                details = 'Proceso anterior finalizado sin publicar.'
            WHERE stage = 'build' AND status = 'running'
            """
        )
        as_of, window_start, inputs = _resolve_inputs(connection, as_of)
        source_hash = _source_set_hash(inputs)
        run_id = uuid4()
        build_id = uuid4()
        started_at = datetime.now(UTC)
        connection.execute(
            """
            INSERT INTO pipeline_runs (
                run_id, stage, as_of_date, build_id, status, source_set_hash, started_at
            ) VALUES (?, 'build', ?, ?, 'running', ?, ?)
            """,
            [str(run_id), as_of, str(build_id), source_hash, started_at],
        )
    except Exception:
        connection.close()
        raise

    try:
        connection.execute("BEGIN TRANSACTION")
        connection.execute(
            """
            CREATE OR REPLACE TEMP TABLE build_context AS
            SELECT ?::UUID AS build_id, ?::DATE AS as_of_date,
                   ?::DATE AS window_start, ?::VARCHAR AS source_set_hash,
                   ?::DATE AS validation_date
            """,
            [
                str(build_id),
                as_of,
                window_start,
                source_hash,
                reference_date or date.today(),
            ],
        )
        for snapshot_date, ingest_run_id, raw_hash in inputs:
            connection.execute(
                """
                INSERT INTO build_inputs (build_id, snapshot_date, ingest_run_id, raw_sha256)
                VALUES (?, ?, ?, ?)
                """,
                [str(build_id), snapshot_date, str(ingest_run_id), raw_hash],
            )
        print("[build] validando grano global...", flush=True)
        _verify_global_grain(connection, build_id)

        mart_sql = (SQL_DIR / "02_marts.sql").read_text(encoding="utf-8")
        for ordinal, statement in enumerate(_split_sql(mart_sql), start=1):
            label = _statement_label(statement)
            statement_started = perf_counter()
            print(f"[build] {ordinal} START {label}", flush=True)
            connection.execute(statement)
            elapsed = perf_counter() - statement_started
            print(f"[build] {ordinal} DONE {label} ({elapsed:.1f}s)", flush=True)
            if failure_after_table == label:
                raise RuntimeError(f"Interrupcion simulada despues de {label}.")

        print("[build] quality_checks...", flush=True)
        connection.execute((SQL_DIR / "03_quality_checks.sql").read_text(encoding="utf-8"))
        _verify_quality_check_inventory(connection, build_id)
        high_failures = connection.execute(
            """
            SELECT test_name, failed_rows
            FROM quality_checks
            WHERE build_id = ? AND severity = 'high'
                AND failed_rows > 0
            ORDER BY test_name
            """,
            [str(build_id)],
        ).fetchall()
        if high_failures:
            raise RuntimeError(f"Quality gate bloqueado: {high_failures}.")
        _verify_lineage(connection, build_id)

        connection.execute("DELETE FROM warehouse_state WHERE singleton")
        connection.execute(
            """
            INSERT INTO warehouse_state (
                singleton, published_build_id, as_of_date, window_start,
                source_set_hash, schema_version, published_at
            ) VALUES (true, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            """,
            [str(build_id), as_of, window_start, source_hash, SCHEMA_VERSION],
        )
        connection.execute(
            """
            UPDATE pipeline_runs
            SET status = 'success', finished_at = CURRENT_TIMESTAMP
            WHERE run_id = ?
            """,
            [str(run_id)],
        )
        connection.execute("COMMIT")
        connection.execute("CHECKPOINT")
        return build_id
    except Exception as error:
        with suppress(duckdb.Error):
            connection.execute("ROLLBACK")
        connection.execute(
            """
            UPDATE pipeline_runs
            SET status = 'failed', finished_at = CURRENT_TIMESTAMP,
                error_count = 1, details = ?
            WHERE run_id = ?
            """,
            [str(error), str(run_id)],
        )
        raise
    finally:
        connection.close()
