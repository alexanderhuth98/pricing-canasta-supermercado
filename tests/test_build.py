from datetime import date

import duckdb
import pytest

from pricing_canasta.build import (
    EXPECTED_QUALITY_CHECKS,
    _split_sql,
    _statement_label,
    build_analytics,
)
from pricing_canasta.config import SQL_DIR
from pricing_canasta.ingest import connect, ingest_snapshot
from pricing_canasta.validate import validate


def _ingest_fixture(database, archives, tmp_path):
    connection = connect(database_path=database, interim_dir=tmp_path / "interim")
    try:
        for archive in archives:
            ingest_snapshot(connection, archive)
    finally:
        connection.close()


def test_full_build_math_and_lineage(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "integration.duckdb"
    _ingest_fixture(database, archives, tmp_path)

    build_id = build_analytics(
        as_of=date(2026, 8, 2),
        database_path=database,
        reference_date=date(2026, 8, 2),
    )
    result = validate(
        database_path=database,
        output_dir=tmp_path / "outputs",
        reference_date=date(2026, 8, 2),
    )
    assert result.build_id == str(build_id)
    assert result.confidence == "Alta"

    connection = duckdb.connect(str(database), read_only=True)
    try:
        assert (
            connection.execute(
                "SELECT COUNT(DISTINCT snapshot_date) FROM mart_price_product_daily"
            ).fetchone()[0]
            == 7
        )
        assert connection.execute(
            "SELECT min(common_gtins), max(common_gtins) FROM mart_banner_index_daily"
        ).fetchone() == (8, 8)
        centers = connection.execute(
            """
            SELECT 100 * exp(avg(ln(price_index / 100)))
            FROM mart_banner_index_daily GROUP BY snapshot_date
            """
        ).fetchall()
        assert all(value[0] == pytest.approx(100, abs=1e-9) for value in centers)
        assert connection.execute("SELECT COUNT(*) FROM dim_basket_component").fetchone()[0] == 8
        basket_cost = connection.execute(
            """
            SELECT branch_median_cost FROM mart_basket_banner_daily
            WHERE snapshot_date = DATE '2026-08-02'
              AND id_comercio = '12' AND id_bandera = '1'
            """
        ).fetchone()[0]
        assert float(basket_cost) == pytest.approx(9069.12, abs=0.01)
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM quality_checks WHERE severity = 'high' AND failed_rows > 0"
            ).fetchone()[0]
            == 0
        )
        assert {
            row[0] for row in connection.execute("SELECT test_name FROM quality_checks").fetchall()
        } == EXPECTED_QUALITY_CHECKS
    finally:
        connection.close()


def test_invalid_geography_never_becomes_publishable(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "invalid_geography.duckdb"
    _ingest_fixture(database, archives, tmp_path)

    connection = duckdb.connect(str(database))
    try:
        connection.execute(
            """
            UPDATE store_snapshot
            SET provincia_codigo = NULL
            WHERE id_comercio IN ('10', '12', '11')
            """
        )
    finally:
        connection.close()

    build_analytics(as_of=date(2026, 8, 2), database_path=database)
    connection = duckdb.connect(str(database), read_only=True)
    try:
        assert (
            connection.execute(
                """
            SELECT COUNT(*)
            FROM mart_dispersion_entity_daily
            WHERE dispersion_level IN ('PROVINCE', 'BANNER_PROVINCE')
              AND (provincia_codigo IS NULL OR provincia_codigo NOT LIKE 'AR-%')
              AND coverage_status = 'PUBLISHABLE'
            """
            ).fetchone()[0]
            == 0
        )
        assert (
            connection.execute(
                """
            SELECT COUNT(*)
            FROM mart_basket_banner_province_daily
            WHERE (provincia_codigo IS NULL OR provincia_codigo NOT LIKE 'AR-%')
              AND coverage_status = 'PUBLISHABLE'
            """
            ).fetchone()[0]
            == 0
        )
        assert (
            connection.execute(
                """
            SELECT failed_rows FROM quality_checks
            WHERE test_name = 'published_invalid_geography'
            """
            ).fetchone()[0]
            == 0
        )
    finally:
        connection.close()


def test_store_count_publication_boundary_for_dispersion_and_basket(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "coverage_boundary.duckdb"
    _ingest_fixture(database, archives, tmp_path)

    connection = duckdb.connect(str(database))
    try:
        connection.execute(
            """
            UPDATE fact_price
            SET precio_lista_valido = false
            WHERE snapshot_date = DATE '2026-08-02'
              AND id_comercio = '12' AND id_bandera = '1' AND id_sucursal = '20'
            """
        )
    finally:
        connection.close()

    build_analytics(
        as_of=date(2026, 8, 2),
        database_path=database,
        reference_date=date(2026, 8, 2),
    )

    connection = duckdb.connect(str(database), read_only=True)
    try:
        dispersion = connection.execute(
            """
            SELECT snapshot_date, min(stores_clean), max(stores_clean),
                   min(coverage_status), max(coverage_status)
            FROM mart_price_dispersion_daily
            WHERE dispersion_level = 'BANNER'
              AND id_comercio = '12' AND id_bandera = '1'
              AND snapshot_date IN (DATE '2026-08-01', DATE '2026-08-02')
            GROUP BY snapshot_date
            ORDER BY snapshot_date
            """
        ).fetchall()
        basket = connection.execute(
            """
            SELECT snapshot_date, complete_stores, coverage_status
            FROM mart_basket_banner_daily
            WHERE id_comercio = '12' AND id_bandera = '1'
              AND snapshot_date IN (DATE '2026-08-01', DATE '2026-08-02')
            ORDER BY snapshot_date
            """
        ).fetchall()
    finally:
        connection.close()

    assert dispersion == [
        (date(2026, 8, 1), 20, 20, "PUBLISHABLE", "PUBLISHABLE"),
        (date(2026, 8, 2), 19, 19, "DIRECTIONAL", "DIRECTIONAL"),
    ]
    assert basket == [
        (date(2026, 8, 1), 20, "PUBLISHABLE"),
        (date(2026, 8, 2), 19, "DIRECTIONAL"),
    ]


def test_index_publication_requires_500_common_gtins():
    connection = duckdb.connect()
    try:
        connection.execute(
            """
            CREATE TABLE mart_banner_product_daily AS
            SELECT
                '12345678-1234-1234-1234-123456789abc'::UUID AS build_id,
                'scope'::VARCHAR AS scope_version,
                DATE '2026-08-01' AS snapshot_date, '12'::VARCHAR AS id_comercio,
                '1'::VARCHAR AS id_bandera, lpad(i::VARCHAR, 14, '0') AS gtin14
            FROM range(500) AS products(i)
            """
        )
        connection.execute(
            """
            INSERT INTO mart_banner_product_daily
            SELECT build_id, scope_version, DATE '2026-08-02', id_comercio, id_bandera, gtin14
            FROM mart_banner_product_daily
            """
        )
        connection.execute(
            """
            CREATE TABLE mart_banner_index_relative_daily AS
            SELECT *, 1.0::DOUBLE AS price_relative
            FROM mart_banner_product_daily
            WHERE snapshot_date = DATE '2026-08-02'
               OR (snapshot_date = DATE '2026-08-01' AND gtin14 != '00000000000499')
            """
        )
        index_statement = next(
            statement
            for statement in _split_sql((SQL_DIR / "02_marts.sql").read_text(encoding="utf-8"))
            if _statement_label(statement) == "mart_banner_index_daily"
        )
        connection.execute(index_statement)

        publication = connection.execute(
            """
            SELECT snapshot_date, common_gtins, publishable
            FROM mart_banner_index_daily
            ORDER BY snapshot_date
            """
        ).fetchall()
    finally:
        connection.close()

    assert publication == [
        (date(2026, 8, 1), 499, False),
        (date(2026, 8, 2), 500, True),
    ]


def test_as_of_requires_exact_seven_day_window(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "as_of.duckdb"
    _ingest_fixture(database, archives[:6], tmp_path)
    with pytest.raises(RuntimeError, match="siete|7 fechas"):
        build_analytics(as_of=date(2026, 8, 1), database_path=database)
    connection = duckdb.connect(str(database))
    connection.close()


def test_build_rejects_duplicate_global_grain(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "duplicate.duckdb"
    _ingest_fixture(database, archives, tmp_path)
    connection = duckdb.connect(str(database))
    try:
        connection.execute("INSERT INTO fact_price SELECT * FROM fact_price LIMIT 1")
    finally:
        connection.close()
    with pytest.raises(RuntimeError, match="Grano global duplicado"):
        build_analytics(as_of=date(2026, 8, 2), database_path=database)


def test_interrupted_build_rolls_back_all_marts(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "rollback.duckdb"
    _ingest_fixture(database, archives, tmp_path)
    published = build_analytics(as_of=date(2026, 8, 2), database_path=database)

    with pytest.raises(RuntimeError, match="Interrupcion simulada"):
        build_analytics(
            as_of=date(2026, 8, 2),
            database_path=database,
            failure_after_table="dim_store_daily",
        )

    connection = duckdb.connect(str(database), read_only=True)
    try:
        assert connection.execute(
            "SELECT published_build_id::VARCHAR FROM warehouse_state"
        ).fetchone()[0] == str(published)
        assert connection.execute(
            "SELECT COUNT(DISTINCT build_id), min(build_id::VARCHAR) FROM dim_store_daily"
        ).fetchone() == (1, str(published))
        assert (
            connection.execute(
                "SELECT status FROM pipeline_runs WHERE stage = 'build' ORDER BY started_at DESC LIMIT 1"
            ).fetchone()[0]
            == "failed"
        )
    finally:
        connection.close()
