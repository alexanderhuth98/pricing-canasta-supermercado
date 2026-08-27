import zipfile
from datetime import date

import pytest
from conftest import create_snapshot_zip

import pricing_canasta.ingest as ingest_module
from pricing_canasta.ingest import SchemaContractError, connect, ingest_all, ingest_snapshot


def test_ingestion_is_idempotent_and_force_replaces(fixture_raw, tmp_path):
    _, archives = fixture_raw
    database = tmp_path / "test.duckdb"
    connection = connect(database_path=database, interim_dir=tmp_path / "interim")
    try:
        first_run = ingest_snapshot(connection, archives[0])
        first_count = connection.execute("SELECT COUNT(*) FROM fact_price").fetchone()[0]
        assert ingest_snapshot(connection, archives[0]) is None
        assert connection.execute("SELECT COUNT(*) FROM fact_price").fetchone()[0] == first_count
        forced_run = ingest_snapshot(connection, archives[0], force=True)
        assert forced_run != first_run
        assert connection.execute("SELECT COUNT(*) FROM fact_price").fetchone()[0] == first_count
    finally:
        connection.close()


def test_idempotent_resume_marks_orphan_ingest_interrupted(fixture_raw, tmp_path):
    _, archives = fixture_raw
    connection = connect(database_path=tmp_path / "resume.duckdb", interim_dir=tmp_path / "interim")
    try:
        ingest_snapshot(connection, archives[0])
        connection.execute(
            """
            INSERT INTO pipeline_runs (
                run_id, stage, snapshot_date, status, force, started_at
            ) VALUES (uuid(), 'ingest', DATE '2026-07-27', 'running', false,
                      CURRENT_TIMESTAMP)
            """
        )
        assert ingest_snapshot(connection, archives[0]) is None
        assert (
            connection.execute(
                """
            SELECT status FROM pipeline_runs
            WHERE stage = 'ingest' AND snapshot_date = DATE '2026-07-27'
            ORDER BY started_at DESC LIMIT 1
            """
            ).fetchone()[0]
            == "interrupted"
        )
    finally:
        connection.close()


def test_failed_force_rolls_back_previous_snapshot(fixture_raw, tmp_path):
    raw_root, archives = fixture_raw
    database = tmp_path / "test.duckdb"
    connection = connect(database_path=database, interim_dir=tmp_path / "interim")
    try:
        ingest_snapshot(connection, archives[0])
        before = connection.execute(
            "SELECT active_ingest_run_id, raw_sha256 FROM snapshot_state"
        ).fetchone()
        count_before = connection.execute("SELECT COUNT(*) FROM fact_price").fetchone()[0]

        def remove_products(chain_index, files):
            if chain_index == 1:
                files.pop("productos.csv")
            return files

        bad = create_snapshot_zip(
            raw_root / "bad", date.fromisoformat(archives[0].parent.name), transform=remove_products
        )
        bad_target = archives[0].parent / "sepa_bad.zip"
        bad_target.write_bytes(bad.read_bytes())
        with pytest.raises(SchemaContractError):
            ingest_snapshot(connection, bad_target, force=True)
        assert connection.execute("SELECT COUNT(*) FROM fact_price").fetchone()[0] == count_before
        assert (
            connection.execute(
                "SELECT active_ingest_run_id, raw_sha256 FROM snapshot_state"
            ).fetchone()
            == before
        )
    finally:
        connection.close()


def test_corrupt_and_empty_outer_fail(tmp_path):
    database = tmp_path / "test.duckdb"
    connection = connect(database_path=database, interim_dir=tmp_path / "interim")
    date_dir = tmp_path / "raw" / "2026-07-27"
    date_dir.mkdir(parents=True)
    empty = date_dir / "empty.zip"
    with zipfile.ZipFile(empty, "w"):
        pass
    try:
        with pytest.raises(SchemaContractError):
            ingest_snapshot(connection, empty)
    finally:
        connection.close()


def test_zip_safety_rejects_member_count_limit(tmp_path, monkeypatch):
    archive_path = tmp_path / "many.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("one.csv", b"1")
        archive.writestr("two.csv", b"2")
    monkeypatch.setattr(ingest_module, "MAX_ZIP_MEMBER_COUNT", 1)
    with (
        zipfile.ZipFile(archive_path) as archive,
        pytest.raises(SchemaContractError, match="miembros ZIP"),
    ):
        ingest_module.validate_zip_safety(archive, archive_path.name)


def test_zip_safety_rejects_member_and_total_uncompressed_limits(tmp_path, monkeypatch):
    archive_path = tmp_path / "large.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("one.csv", b"1234")
        archive.writestr("two.csv", b"5678")

    monkeypatch.setattr(ingest_module, "MAX_ZIP_MEMBER_BYTES", 3)
    with (
        zipfile.ZipFile(archive_path) as archive,
        pytest.raises(SchemaContractError, match="maximo descomprimido"),
    ):
        ingest_module.validate_zip_safety(archive, archive_path.name)

    monkeypatch.setattr(ingest_module, "MAX_ZIP_MEMBER_BYTES", 10)
    monkeypatch.setattr(ingest_module, "MAX_ZIP_TOTAL_BYTES", 7)
    with (
        zipfile.ZipFile(archive_path) as archive,
        pytest.raises(SchemaContractError, match="maximo total"),
    ):
        ingest_module.validate_zip_safety(archive, archive_path.name)


def test_zip_safety_rejects_excessive_compression_ratio(tmp_path, monkeypatch):
    archive_path = tmp_path / "bomb.zip"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("repeated.csv", b"0" * 10_000)
    monkeypatch.setattr(ingest_module, "MAX_ZIP_COMPRESSION_RATIO", 10)
    with (
        zipfile.ZipFile(archive_path) as archive,
        pytest.raises(SchemaContractError, match="Ratio de compresion"),
    ):
        ingest_module.validate_zip_safety(archive, archive_path.name)


def test_wrong_header_fails_without_publishing(tmp_path):
    def reorder_header(chain_index, files):
        if chain_index == 1:
            lines = files["productos.csv"].splitlines(keepends=True)
            columns = lines[0].decode("utf-8").strip().split("|")
            columns[0], columns[1] = columns[1], columns[0]
            files["productos.csv"] = ("|".join(columns) + "\r\n").encode() + b"".join(lines[1:])
        return files

    archive = create_snapshot_zip(tmp_path / "raw", date(2026, 7, 27), transform=reorder_header)
    connection = connect(
        database_path=tmp_path / "bad_header.duckdb", interim_dir=tmp_path / "interim"
    )
    try:
        with pytest.raises(SchemaContractError, match="Esquema CSV incompatible"):
            ingest_snapshot(connection, archive)
        assert connection.execute("SELECT COUNT(*) FROM snapshot_state").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM fact_price").fetchone()[0] == 0
    finally:
        connection.close()


def test_malformed_quoted_row_fails_strict_parser(tmp_path):
    def break_quoting(chain_index, files):
        if chain_index == 1:
            footer = b"\r\nUltima actualizacion: 2026-08-02T04:00:00-03:00\r\n"
            files["productos.csv"] = files["productos.csv"].replace(
                footer, b'\r\n1|1|1|4006381333931|1|"sin cierre\r\n' + footer
            )
        return files

    archive = create_snapshot_zip(tmp_path / "raw", date(2026, 7, 27), transform=break_quoting)
    connection = connect(
        database_path=tmp_path / "malformed.duckdb", interim_dir=tmp_path / "interim"
    )
    try:
        with pytest.raises(Exception, match="CSV|quote|quoted|column|delimiter"):
            ingest_snapshot(connection, archive)
        assert connection.execute("SELECT COUNT(*) FROM snapshot_state").fetchone()[0] == 0
    finally:
        connection.close()


def test_blank_productos_ean_is_loaded_as_false(tmp_path):
    def blank_ean(chain_index, files):
        if chain_index == 1:
            files["productos.csv"] = files["productos.csv"].replace(
                b"|1|ACEITE DE GIRASOL", b"||ACEITE DE GIRASOL"
            )
        return files

    archive = create_snapshot_zip(tmp_path / "raw", date(2026, 7, 27), transform=blank_ean)
    connection = connect(
        database_path=tmp_path / "blank_ean.duckdb",
        interim_dir=tmp_path / "interim",
    )
    try:
        ingest_snapshot(connection, archive)
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM fact_price WHERE NOT productos_ean"
            ).fetchone()[0]
            > 0
        )
    finally:
        connection.close()


def test_ingest_all_fails_when_filters_select_no_snapshot(fixture_raw, tmp_path, monkeypatch):
    raw_root, _ = fixture_raw
    monkeypatch.setattr(ingest_module, "RAW_DIR", raw_root)
    with pytest.raises(FileNotFoundError, match="only_snapshot"):
        ingest_all(
            only_snapshot=date(2026, 8, 10),
            database_path=tmp_path / "filtered.duckdb",
        )
