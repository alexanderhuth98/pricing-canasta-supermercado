from datetime import date, datetime, timedelta

import duckdb
import pytest

from pricing_canasta.build import EXPECTED_QUALITY_CHECKS, REQUIRED_BUILD_TABLES
from pricing_canasta.config import SCHEMA_VERSION
from pricing_canasta.validate import validate

BUILD_ID = "12345678-1234-1234-1234-123456789abc"
MEDIUM_CHECKS = {
    "critical_price_anomalies",
    "invalid_list_prices",
    "invalid_or_missing_geography",
    "invalid_source_product_codes",
    "known_empty_source_packages",
    "reconstructed_source_lines",
    "source_null_keys",
    "stale_as_of_date",
    "unhealthy_scope_banner_days",
    "unhealthy_snapshot_days",
}


def _validation_database(
    path,
    *,
    as_of_date=date(2026, 8, 2),
    healthy_days=(True, True, True, True, True),
    failed_check=None,
    omitted_check=None,
    snapshot_healthy=True,
):
    connection = duckdb.connect(str(path))
    try:
        connection.execute(
            """
            CREATE TABLE warehouse_state (
                singleton BOOLEAN, published_build_id UUID, as_of_date DATE,
                window_start DATE, source_set_hash VARCHAR, schema_version VARCHAR,
                published_at TIMESTAMP
            )
            """
        )
        connection.execute(
            "INSERT INTO warehouse_state VALUES (true, ?, ?, ?, 'hash', ?, ?)",
            [BUILD_ID, as_of_date, as_of_date - timedelta(days=6), SCHEMA_VERSION, datetime.now()],
        )

        specialized = {
            "quality_checks",
            "mart_banner_day_health",
            "mart_basket_store_daily",
            "mart_banner_index_daily",
        }
        for table in REQUIRED_BUILD_TABLES:
            if table not in specialized:
                connection.execute(f"CREATE TABLE {table} (build_id UUID)")
                connection.execute(f"INSERT INTO {table} VALUES (?)", [BUILD_ID])

        connection.execute(
            "CREATE TABLE quality_checks "
            "(build_id UUID, test_name VARCHAR, failed_rows BIGINT, severity VARCHAR, details VARCHAR)"
        )
        check_rows = [
            (
                BUILD_ID,
                name,
                1 if name == failed_check else 0,
                "medium" if name in MEDIUM_CHECKS else "high",
                "test fixture",
            )
            for name in sorted(EXPECTED_QUALITY_CHECKS)
            if name != omitted_check
        ]
        connection.executemany("INSERT INTO quality_checks VALUES (?, ?, ?, ?, ?)", check_rows)

        connection.execute(
            "CREATE TABLE mart_banner_day_health "
            "(build_id UUID, snapshot_date DATE, source_healthy BOOLEAN)"
        )
        connection.executemany(
            "INSERT INTO mart_banner_day_health VALUES (?, ?, ?)",
            [
                (BUILD_ID, as_of_date - timedelta(days=offset), healthy)
                for offset, healthy in enumerate(healthy_days)
            ],
        )
        connection.execute(
            "CREATE TABLE mart_snapshot_health (build_id UUID, source_healthy BOOLEAN)"
        )
        connection.execute(
            "INSERT INTO mart_snapshot_health VALUES (?, ?)", [BUILD_ID, snapshot_healthy]
        )
        connection.execute("CREATE TABLE build_inputs (build_id UUID)")
        connection.executemany(
            "INSERT INTO build_inputs VALUES (?)", [(BUILD_ID,) for _ in range(7)]
        )
        connection.execute(
            "CREATE TABLE mart_quality_daily "
            "(build_id UUID, source_rows BIGINT, global_gtin_rows BIGINT, "
            "restricted_local_rows BIGINT)"
        )
        connection.execute("INSERT INTO mart_quality_daily VALUES (?, 100, 90, 10)", [BUILD_ID])
        connection.execute("CREATE TABLE dim_basket_component (build_id UUID)")
        connection.execute("INSERT INTO dim_basket_component VALUES (?)", [BUILD_ID])
        connection.execute(
            "CREATE TABLE mart_basket_store_daily (build_id UUID, complete_basket BOOLEAN)"
        )
        connection.execute("INSERT INTO mart_basket_store_daily VALUES (?, true)", [BUILD_ID])
        connection.execute(
            "CREATE TABLE mart_banner_index_daily (build_id UUID, snapshot_date DATE)"
        )
        connection.execute(
            "INSERT INTO mart_banner_index_daily VALUES (?, ?)", [BUILD_ID, as_of_date]
        )
    finally:
        connection.close()


@pytest.mark.parametrize(
    ("age_days", "healthy_days", "failed_check", "snapshot_healthy", "expected"),
    [
        (14, (True, True, True, True, False), None, True, "Alta"),
        (15, (True, True, True, True, False), None, True, "Media"),
        (30, (True, True, True, True, False), None, True, "Media"),
        (31, (True, True, True, True, False), None, True, "Baja"),
        (0, (True, True, True, False), None, True, "Baja"),
        (0, (True,), "invalid_list_prices", True, "Media"),
        (0, (True,), None, False, "Media"),
    ],
)
def test_validation_confidence_boundaries(
    tmp_path, age_days, healthy_days, failed_check, snapshot_healthy, expected
):
    database = tmp_path / "validation.duckdb"
    as_of_date = date(2026, 8, 2)
    _validation_database(
        database,
        as_of_date=as_of_date,
        healthy_days=healthy_days,
        failed_check=failed_check,
        snapshot_healthy=snapshot_healthy,
    )

    result = validate(
        database_path=database,
        output_dir=tmp_path / "outputs",
        reference_date=as_of_date + timedelta(days=age_days),
    )

    assert result.confidence == expected
    assert "**" + expected + "**" in result.report_path.read_text(encoding="utf-8")


def test_high_failure_blocks_publication_after_writing_report(tmp_path):
    database = tmp_path / "failed.duckdb"
    output_dir = tmp_path / "outputs"
    _validation_database(database, failed_check="basket_component_count")

    with pytest.raises(RuntimeError, match=r"Quality gate bloqueado: 1 fallas altas"):
        validate(
            database_path=database,
            output_dir=output_dir,
            reference_date=date(2026, 8, 2),
        )

    report = (output_dir / "validation_report.md").read_text(encoding="utf-8")
    assert "| basket_component_count | 1 | high |" in report
    assert "**Baja**" in report


def test_missing_quality_check_inventory_blocks_publication(tmp_path):
    database = tmp_path / "missing_check.duckdb"
    output_dir = tmp_path / "outputs"
    _validation_database(database, omitted_check="index_geometric_center")

    with pytest.raises(RuntimeError, match=r"Quality gate bloqueado: 1 fallas altas"):
        validate(
            database_path=database,
            output_dir=output_dir,
            reference_date=date(2026, 8, 2),
        )

    report = (output_dir / "validation_report.md").read_text(encoding="utf-8")
    assert "faltantes=['index_geometric_center']" in report
