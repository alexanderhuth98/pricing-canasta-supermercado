from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path

import duckdb

from .build import EXPECTED_QUALITY_CHECKS, NONEMPTY_BUILD_TABLES, REQUIRED_BUILD_TABLES
from .config import DATABASE_PATH, OUTPUT_DIR, SCHEMA_VERSION, ensure_directories


@dataclass(frozen=True)
class ValidationResult:
    build_id: str
    as_of_date: date
    confidence: str
    high_failures: int
    medium_failures: int
    report_path: Path


def _lineage_failures(connection: duckdb.DuckDBPyConnection, build_id: str) -> list[str]:
    existing = {row[0] for row in connection.execute("SHOW TABLES").fetchall()}
    failures = []
    for table in REQUIRED_BUILD_TABLES:
        if table not in existing:
            failures.append(f"Falta la tabla {table}")
            continue
        row_count, distinct_count, minimum_id = connection.execute(
            f"SELECT COUNT(*), COUNT(DISTINCT build_id), min(build_id::VARCHAR) FROM {table}"
        ).fetchone()
        if row_count == 0 and table in NONEMPTY_BUILD_TABLES:
            failures.append(f"La tabla requerida {table} esta vacia")
            continue
        if row_count and (distinct_count != 1 or minimum_id != build_id):
            failures.append(
                f"{table} contiene build_ids incompatibles: {(distinct_count, minimum_id)}"
            )
    return failures


def validate(
    database_path: Path = DATABASE_PATH,
    raise_on_failure: bool = True,
    output_dir: Path | None = None,
    reference_date: date | None = None,
) -> ValidationResult:
    ensure_directories()
    output_dir = output_dir or OUTPUT_DIR
    output_dir.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        state = connection.execute(
            """
            SELECT published_build_id::VARCHAR, as_of_date, window_start,
                   source_set_hash, schema_version, published_at
            FROM warehouse_state
            WHERE singleton
            """
        ).fetchone()
        if not state:
            raise RuntimeError("No existe un build publicado en warehouse_state.")
        build_id, as_of_date, window_start, source_hash, schema_version, published_at = state
        if schema_version != SCHEMA_VERSION:
            raise RuntimeError(
                f"Schema publicado={schema_version}; codigo esperado={SCHEMA_VERSION}."
            )
        lineage = _lineage_failures(connection, build_id)
        checks = connection.execute(
            """
            SELECT test_name, failed_rows, severity, details
            FROM quality_checks
            WHERE build_id = ?
            ORDER BY CASE severity WHEN 'high' THEN 1 ELSE 2 END, test_name
            """,
            [build_id],
        ).fetchall()
        actual_checks = {row[0] for row in checks}
        if actual_checks != EXPECTED_QUALITY_CHECKS:
            missing = sorted(EXPECTED_QUALITY_CHECKS - actual_checks)
            extra = sorted(actual_checks - EXPECTED_QUALITY_CHECKS)
            lineage.append(
                f"Inventario de quality checks invalido: faltantes={missing}; extras={extra}"
            )
        high_failures = sum(int(row[1] or 0) for row in checks if row[2] == "high")
        medium_failures = sum(int(row[1] or 0) for row in checks if row[2] == "medium")
        health = connection.execute(
            """
            SELECT
                COUNT(*) AS scope_days,
                COUNT(*) FILTER (WHERE source_healthy) AS healthy_scope_days,
                COUNT(DISTINCT snapshot_date) AS observed_dates
            FROM mart_banner_day_health
            WHERE build_id = ?
            """,
            [build_id],
        ).fetchone()
        snapshot_health = connection.execute(
            """
            SELECT COUNT(*) FILTER (WHERE NOT source_healthy)
            FROM mart_snapshot_health WHERE build_id = ?
            """,
            [build_id],
        ).fetchone()[0]
        input_rows = connection.execute(
            "SELECT COUNT(*) FROM build_inputs WHERE build_id = ?", [build_id]
        ).fetchone()[0]
        price_rows, global_rows, restricted_rows = connection.execute(
            """
            SELECT sum(source_rows), sum(global_gtin_rows), sum(restricted_local_rows)
            FROM mart_quality_daily WHERE build_id = ?
            """,
            [build_id],
        ).fetchone()
        basket = connection.execute(
            """
            SELECT COUNT(*),
                   (SELECT COUNT(*) FROM mart_basket_store_daily
                    WHERE build_id = ? AND complete_basket)
            FROM dim_basket_component WHERE build_id = ?
            """,
            [build_id, build_id],
        ).fetchone()
        index_days = connection.execute(
            "SELECT COUNT(DISTINCT snapshot_date) FROM mart_banner_index_daily WHERE build_id = ?",
            [build_id],
        ).fetchone()[0]
    finally:
        connection.close()

    healthy_ratio = health[1] / health[0] if health[0] else 0
    freshness_days = ((reference_date or date.today()) - as_of_date).days
    if high_failures or lineage or input_rows != 7 or freshness_days > 30 or healthy_ratio < 0.80:
        confidence = "Baja"
    elif medium_failures or snapshot_health or freshness_days > 14:
        confidence = "Media"
    else:
        confidence = "Alta"

    check_rows = "\n".join(
        f"| {name} | {int(failed or 0):,} | {severity} | {details} |"
        for name, failed, severity, details in checks
    )
    lineage_rows = "\n".join(f"- {failure}" for failure in lineage) or "- Sin fallas."
    generated_at = datetime.now(UTC).isoformat()
    content = f"""# Informe de validacion

## Checklist

- Build publicado: `{build_id}`.
- Generado UTC: `{generated_at}`.
- Esquema: `{schema_version}`.
- Ventana: {window_start} a {as_of_date}.
- Antiguedad del corte: {freshness_days} dias.
- Inputs versionados: {input_rows}.
- Filas fuente: {int(price_rows or 0):,}.
- Filas GTIN global: {int(global_rows or 0):,}.
- Filas de codigos restringidos separadas: {int(restricted_rows or 0):,}.
- Salud cadena-dia: {health[1]}/{health[0]} ({healthy_ratio:.1%}).
- Dias completos del snapshot nacional con advertencia: {int(snapshot_health or 0)}.
- Componentes fijos de canasta: {basket[0]}.
- Canastas completas sucursal-dia: {basket[1]:,}.
- Dias publicables del indice comun: {index_days}.

## Quality gates

| Test | Fallas | Severidad | Interpretacion |
|---|---:|---|---|
{check_rows}

## Linaje

{lineage_rows}

## Confianza

**{confidence}**.

La confianza evalua calidad, frescura, salud de fuente y anomalias del corte publicado.
La ventana de siete dias limita conclusiones estructurales o de tendencia, pero no
reduce mecanicamente la calidad de datos si todos los controles son satisfactorios.
"""
    report_path = output_dir / "validation_report.md"
    report_path.write_text(content, encoding="utf-8")
    result = ValidationResult(
        build_id=build_id,
        as_of_date=as_of_date,
        confidence=confidence,
        high_failures=high_failures + len(lineage),
        medium_failures=medium_failures,
        report_path=report_path,
    )
    if raise_on_failure and result.high_failures:
        raise RuntimeError(
            f"Quality gate bloqueado: {result.high_failures} fallas altas. "
            f"Consulta {report_path}."
        )
    return result


if __name__ == "__main__":
    print(validate().report_path)
