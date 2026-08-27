import csv
import hashlib
import os
import re
import shutil
import unicodedata
import zipfile
from contextlib import suppress
from datetime import UTC, date, datetime
from pathlib import Path
from typing import BinaryIO
from uuid import UUID, uuid4

import duckdb

from .config import (
    DATABASE_PATH,
    DUCKDB_THREADS,
    EXPECTED_COLUMNS,
    INTERIM_DIR,
    KNOWN_EMPTY_PACKAGE_PATTERN,
    RAW_DIR,
    SQL_DIR,
    ensure_directories,
)


class SchemaContractError(ValueError):
    """Raised when a SEPA CSV does not match the documented schema."""


MAX_ZIP_MEMBER_COUNT = int(os.getenv("MAX_ZIP_MEMBER_COUNT", "10000"))
MAX_ZIP_MEMBER_BYTES = int(os.getenv("MAX_ZIP_MEMBER_BYTES", str(4 * 1024**3)))
MAX_ZIP_TOTAL_BYTES = int(os.getenv("MAX_ZIP_TOTAL_BYTES", str(32 * 1024**3)))
MAX_ZIP_COMPRESSION_RATIO = float(os.getenv("MAX_ZIP_COMPRESSION_RATIO", "200"))


def validate_zip_safety(archive: zipfile.ZipFile, archive_name: str) -> None:
    members = archive.infolist()
    if len(members) > MAX_ZIP_MEMBER_COUNT:
        raise SchemaContractError(
            f"{archive_name} excede el maximo de miembros ZIP: "
            f"{len(members)} > {MAX_ZIP_MEMBER_COUNT}."
        )

    total_size = 0
    for member in members:
        if member.file_size > MAX_ZIP_MEMBER_BYTES:
            raise SchemaContractError(
                f"{archive_name}/{member.filename} excede el maximo descomprimido: "
                f"{member.file_size} > {MAX_ZIP_MEMBER_BYTES} bytes."
            )
        total_size += member.file_size
        if total_size > MAX_ZIP_TOTAL_BYTES:
            raise SchemaContractError(
                f"{archive_name} excede el maximo total descomprimido: "
                f"{total_size} > {MAX_ZIP_TOTAL_BYTES} bytes."
            )
        if member.file_size:
            if member.compress_size <= 0:
                raise SchemaContractError(
                    f"Tamano comprimido invalido en {archive_name}/{member.filename}."
                )
            ratio = member.file_size / member.compress_size
            if ratio > MAX_ZIP_COMPRESSION_RATIO:
                raise SchemaContractError(
                    f"Ratio de compresion excesivo en {archive_name}/{member.filename}: "
                    f"{ratio:.1f} > {MAX_ZIP_COMPRESSION_RATIO}."
                )


def file_sha256(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sql_literal(value: object) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _column_map(columns: list[str]) -> str:
    return "{" + ", ".join(f"'{column}': 'VARCHAR'" for column in columns) + "}"


def _fold_text(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    return normalized.encode("ascii", "ignore").decode("ascii").lower()


def _is_footer(line: bytes) -> bool:
    if b"|" in line:
        return False
    sample = line.decode("utf-8", errors="replace")
    return bool(
        re.fullmatch(
            r"\s*ultima\s+actualizacion\s*:\s*\S.*",
            _fold_text(sample),
        )
    )


def _parse_header(raw_header: bytes) -> list[str]:
    try:
        decoded = raw_header.decode("utf-8-sig", errors="strict").strip("\r\n")
        parsed = next(csv.reader([decoded], delimiter="|", quotechar='"', strict=True))
    except (UnicodeDecodeError, csv.Error) as error:
        raise SchemaContractError(f"Encabezado CSV invalido: {error}") from error
    return [column.strip() for column in parsed]


def validate_header(raw_header: bytes, expected_columns: list[str]) -> None:
    actual = _parse_header(raw_header)
    if len(actual) != len(set(actual)):
        raise SchemaContractError(f"El encabezado contiene columnas duplicadas: {actual}")
    if actual != expected_columns:
        missing = [column for column in expected_columns if column not in actual]
        extra = [column for column in actual if column not in expected_columns]
        raise SchemaContractError(
            "Esquema CSV incompatible. "
            f"Esperado={expected_columns}; recibido={actual}; "
            f"faltantes={missing}; adicionales={extra}."
        )


def _field_count(line: bytes) -> int:
    try:
        decoded = line.decode("utf-8", errors="strict")
        return len(next(csv.reader([decoded], delimiter="|", quotechar='"', strict=True)))
    except (UnicodeDecodeError, csv.Error) as error:
        raise SchemaContractError(f"Registro CSV invalido: {error}") from error


def sanitize_csv(source: BinaryIO, destination: Path, columns: list[str]) -> dict:
    """Validate the header and remove only documented transport artifacts."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_rows = 0
    footer_rows = 0
    null_bytes_removed = 0
    reconstructed_lines = 0

    raw_header = None
    for candidate in source:
        if candidate.strip():
            raw_header = candidate
            break
    if raw_header is None:
        raise SchemaContractError("CSV vacio: no contiene encabezado.")
    validate_header(raw_header.replace(b"\x00", b""), columns)
    null_bytes_removed += raw_header.count(b"\x00")

    pending_line = None
    with destination.open("wb") as output:
        output.write(("|".join(columns) + "\n").encode("utf-8"))
        for raw_line in source:
            null_bytes_removed += raw_line.count(b"\x00")
            line = raw_line.replace(b"\x00", b"").strip(b"\r\n")
            if not line.strip():
                continue
            if (
                pending_line is not None
                and line.startswith(b"|")
                and _field_count(pending_line) < len(columns)
            ):
                pending_line += line
                reconstructed_lines += 1
                continue
            if pending_line is not None:
                output.write(pending_line + b"\n")
                source_rows += 1
            pending_line = line

        if pending_line is not None:
            if _is_footer(pending_line):
                footer_rows = 1
            else:
                output.write(pending_line + b"\n")
                source_rows += 1

    if source_rows == 0:
        raise SchemaContractError("CSV sin registros de datos.")
    return {
        "source_rows": source_rows,
        "footer_rows": footer_rows,
        "null_bytes_removed": null_bytes_removed,
        "reconstructed_lines": reconstructed_lines,
    }


def connect(
    database_path: Path = DATABASE_PATH,
    interim_dir: Path = INTERIM_DIR,
) -> duckdb.DuckDBPyConnection:
    ensure_directories()
    database_path.parent.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(str(database_path))
    temp_dir = interim_dir / "duckdb_temp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    connection.execute(f"SET temp_directory={_sql_literal(temp_dir.resolve())}")
    connection.execute("SET preserve_insertion_order=false")
    connection.execute(f"SET threads={DUCKDB_THREADS}")
    connection.execute((SQL_DIR / "01_schema.sql").read_text(encoding="utf-8"))
    return connection


def _read_csv_sql(path: Path, columns: list[str]) -> str:
    return (
        "read_csv("
        f"{_sql_literal(path.resolve())}, "
        "delim='|', header=true, quote='\"', escape='\"', "
        "ignore_errors=false, null_padding=false, strict_mode=true, "
        "auto_detect=false, encoding='utf-8', "
        f"columns={_column_map(columns)})"
    )


def _load_commerce(
    connection: duckdb.DuckDBPyConnection,
    csv_path: Path,
    snapshot_date: str,
    package: str,
    run_id: UUID,
) -> int:
    source = _read_csv_sql(csv_path, EXPECTED_COLUMNS["comercio.csv"])
    connection.execute(f"CREATE OR REPLACE TEMP TABLE import_batch AS SELECT * FROM {source}")
    loaded = connection.execute("SELECT COUNT(*) FROM import_batch").fetchone()[0]
    connection.execute(
        f"""
        INSERT INTO commerce_snapshot (
            ingest_run_id, snapshot_date, source_package, id_comercio, id_bandera,
            comercio_cuit, comercio_razon_social, comercio_bandera_nombre,
            comercio_bandera_url, comercio_ultima_actualizacion, comercio_version_sepa
        )
        SELECT
            UUID {_sql_literal(run_id)}, DATE {_sql_literal(snapshot_date)},
            {_sql_literal(package)}, nullif(trim(id_comercio), ''),
            nullif(trim(id_bandera), ''), nullif(trim(comercio_cuit), ''),
            nullif(trim(comercio_razon_social), ''),
            nullif(trim(comercio_bandera_nombre), ''),
            nullif(trim(comercio_bandera_url), ''),
            try_cast(nullif(trim(comercio_ultima_actualizacion), '') AS TIMESTAMPTZ),
            nullif(trim(comercio_version_sepa), '')
        FROM import_batch
        """
    )
    return loaded


def _load_stores(
    connection: duckdb.DuckDBPyConnection,
    csv_path: Path,
    snapshot_date: str,
    package: str,
    run_id: UUID,
) -> int:
    source = _read_csv_sql(csv_path, EXPECTED_COLUMNS["sucursales.csv"])
    connection.execute(f"CREATE OR REPLACE TEMP TABLE import_batch AS SELECT * FROM {source}")
    loaded = connection.execute("SELECT COUNT(*) FROM import_batch").fetchone()[0]
    connection.execute(
        f"""
        INSERT INTO store_snapshot (
            ingest_run_id, snapshot_date, source_package, id_comercio, id_bandera,
            id_sucursal, sucursal_nombre, sucursal_tipo, calle, numero, latitud,
            longitud, observaciones, barrio, codigo_postal, localidad,
            provincia_codigo, lunes_horario, martes_horario, miercoles_horario,
            jueves_horario, viernes_horario, sabado_horario, domingo_horario,
            coordenadas_validas
        )
        WITH typed AS (
            SELECT *,
                try_cast(nullif(trim(sucursales_latitud), '') AS DOUBLE) AS latitude,
                try_cast(nullif(trim(sucursales_longitud), '') AS DOUBLE) AS longitude
            FROM import_batch
        )
        SELECT
            UUID {_sql_literal(run_id)}, DATE {_sql_literal(snapshot_date)},
            {_sql_literal(package)}, nullif(trim(id_comercio), ''),
            nullif(trim(id_bandera), ''), nullif(trim(id_sucursal), ''),
            nullif(trim(sucursales_nombre), ''), nullif(trim(sucursales_tipo), ''),
            nullif(trim(sucursales_calle), ''), nullif(trim(sucursales_numero), ''),
            latitude, longitude, nullif(trim(sucursales_observaciones), ''),
            nullif(trim(sucursales_barrio), ''),
            nullif(trim(sucursales_codigo_postal), ''),
            nullif(trim(sucursales_localidad), ''),
            nullif(trim(sucursales_provincia), ''),
            nullif(trim(sucursales_lunes_horario_atencion), ''),
            nullif(trim(sucursales_martes_horario_atencion), ''),
            nullif(trim(sucursales_miercoles_horario_atencion), ''),
            nullif(trim(sucursales_jueves_horario_atencion), ''),
            nullif(trim(sucursales_viernes_horario_atencion), ''),
            nullif(trim(sucursales_sabado_horario_atencion), ''),
            nullif(trim(sucursales_domingo_horario_atencion), ''),
            coalesce(latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180, false)
        FROM typed
        """
    )
    return loaded


def _load_prices(
    connection: duckdb.DuckDBPyConnection,
    csv_path: Path,
    snapshot_date: str,
    package: str,
    run_id: UUID,
) -> int:
    source = _read_csv_sql(csv_path, EXPECTED_COLUMNS["productos.csv"])
    connection.execute(f"CREATE OR REPLACE TEMP TABLE import_batch AS SELECT * FROM {source}")
    loaded = connection.execute("SELECT COUNT(*) FROM import_batch").fetchone()[0]
    connection.execute(
        f"""
        INSERT INTO fact_price (
            ingest_run_id, snapshot_date, source_package, id_comercio, id_bandera,
            id_sucursal, id_producto, productos_ean, gtin14, gtin_valido,
            product_code_scope, producto_descripcion, producto_descripcion_normalizada,
            cantidad_presentacion, unidad_presentacion, marca, precio_lista,
            precio_referencia, cantidad_referencia, unidad_referencia,
            precio_promo_general, leyenda_promo_general, precio_promo_segmentada,
            leyenda_promo_segmentada, precio_lista_valido
        )
        WITH normalized AS (
            SELECT *,
                coalesce(
                    lower(trim(productos_ean)) IN ('1', 'true', 't', 'si', 'sí'),
                    false
                ) AS is_ean,
                normalize_gtin14(id_producto, productos_ean) AS normalized_gtin,
                try_cast(nullif(trim(productos_precio_lista), '') AS DECIMAL(18, 4))
                    AS list_price
            FROM import_batch
        ), validated AS (
            SELECT *, is_valid_gtin14(normalized_gtin) AS valid_gtin
            FROM normalized
        )
        SELECT
            UUID {_sql_literal(run_id)}, DATE {_sql_literal(snapshot_date)},
            {_sql_literal(package)}, nullif(trim(id_comercio), ''),
            nullif(trim(id_bandera), ''), nullif(trim(id_sucursal), ''),
            nullif(trim(id_producto), ''), is_ean, normalized_gtin, valid_gtin,
            classify_product_code(id_producto, is_ean, valid_gtin),
            nullif(trim(productos_descripcion), ''),
            upper(strip_accents(nullif(trim(productos_descripcion), ''))),
            try_cast(nullif(trim(productos_cantidad_presentacion), '') AS DOUBLE),
            normalize_unit(productos_unidad_medida_presentacion),
            nullif(trim(productos_marca), ''), list_price,
            try_cast(nullif(trim(productos_precio_referencia), '') AS DECIMAL(18, 4)),
            try_cast(nullif(trim(productos_cantidad_referencia), '') AS DOUBLE),
            normalize_unit(productos_unidad_medida_referencia),
            try_cast(nullif(trim(productos_precio_unitario_promo1), '') AS DECIMAL(18, 4)),
            nullif(trim(productos_leyenda_promo1), ''),
            try_cast(nullif(trim(productos_precio_unitario_promo2), '') AS DECIMAL(18, 4)),
            nullif(trim(productos_leyenda_promo2), ''),
            coalesce(list_price > 0, false)
        FROM validated
        """
    )
    return loaded


LOADERS = {
    "comercio.csv": _load_commerce,
    "sucursales.csv": _load_stores,
    "productos.csv": _load_prices,
}


def _log_ingestion(
    connection: duckdb.DuckDBPyConnection,
    run_id: UUID,
    snapshot_date: str,
    package: str,
    file_name: str,
    metrics: dict,
    loaded_rows: int,
    status: str = "success",
    details: str | None = None,
) -> None:
    connection.execute(
        """
        INSERT INTO ingestion_log (
            ingest_run_id, snapshot_date, source_package, file_name, source_rows,
            loaded_rows, footer_rows, null_bytes_removed, reconstructed_lines,
            status, details
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            str(run_id),
            snapshot_date,
            package,
            file_name,
            metrics.get("source_rows"),
            loaded_rows,
            metrics.get("footer_rows", 0),
            metrics.get("null_bytes_removed", 0),
            metrics.get("reconstructed_lines", 0),
            status,
            details,
        ],
    )


def _required_members(inner: zipfile.ZipFile) -> dict[str, str]:
    by_basename: dict[str, list[str]] = {}
    for name in inner.namelist():
        basename = Path(name).name.lower()
        if basename:
            by_basename.setdefault(basename, []).append(name)
    duplicated = {name: paths for name, paths in by_basename.items() if len(paths) > 1}
    if duplicated:
        raise SchemaContractError(f"Miembros CSV ambiguos: {duplicated}")
    missing = [name for name in EXPECTED_COLUMNS if name not in by_basename]
    if missing:
        raise SchemaContractError(f"Archivos requeridos ausentes: {missing}")
    return {name: by_basename[name][0] for name in EXPECTED_COLUMNS}


def _ingest_package(
    connection: duckdb.DuckDBPyConnection,
    outer: zipfile.ZipFile,
    member: zipfile.ZipInfo,
    snapshot_date: str,
    work_dir: Path,
    run_id: UUID,
) -> tuple[int, int]:
    package_name = Path(member.filename).name
    if member.file_size == 0:
        if not re.search(KNOWN_EMPTY_PACKAGE_PATTERN, package_name, flags=re.IGNORECASE):
            raise SchemaContractError(f"Paquete ZIP vacio no autorizado: {package_name}")
        _log_ingestion(
            connection,
            run_id,
            snapshot_date,
            package_name,
            package_name,
            {},
            0,
            "source_empty",
            "Paquete vacio conocido y explicitamente permitido.",
        )
        return 0, 1

    package_zip = work_dir / package_name
    with outer.open(member) as source, package_zip.open("wb") as destination:
        shutil.copyfileobj(source, destination, length=8 * 1024 * 1024)

    warnings = 0
    try:
        with zipfile.ZipFile(package_zip) as inner:
            validate_zip_safety(inner, package_name)
            bad_member = inner.testzip()
            if bad_member:
                raise zipfile.BadZipFile(f"CRC invalido en {bad_member}")
            members = _required_members(inner)
            for file_name, columns in EXPECTED_COLUMNS.items():
                sanitized_path = work_dir / f"{package_zip.stem}_{file_name}"
                with inner.open(members[file_name]) as source:
                    metrics = sanitize_csv(source, sanitized_path, columns)
                try:
                    loaded_rows = LOADERS[file_name](
                        connection, sanitized_path, snapshot_date, package_name, run_id
                    )
                    if loaded_rows != metrics["source_rows"]:
                        raise SchemaContractError(
                            f"Diferencia de filas en {package_name}/{file_name}: "
                            f"fuente={metrics['source_rows']}, cargadas={loaded_rows}."
                        )
                    if metrics["null_bytes_removed"]:
                        warnings += 1
                    _log_ingestion(
                        connection,
                        run_id,
                        snapshot_date,
                        package_name,
                        file_name,
                        metrics,
                        loaded_rows,
                    )
                    print(
                        f"[ingest] {snapshot_date} {package_name} {file_name}: "
                        f"{loaded_rows:,} filas",
                        flush=True,
                    )
                finally:
                    sanitized_path.unlink(missing_ok=True)
    finally:
        package_zip.unlink(missing_ok=True)
    return 1, warnings


def _validate_outer(outer: zipfile.ZipFile, snapshot_date: str) -> list[zipfile.ZipInfo]:
    validate_zip_safety(outer, f"snapshot {snapshot_date}")
    packages = [member for member in outer.infolist() if member.filename.lower().endswith(".zip")]
    if not packages:
        raise SchemaContractError("El ZIP exterior no contiene paquetes ZIP interiores.")
    roots = {Path(member.filename).parts[0] for member in packages if Path(member.filename).parts}
    if roots != {snapshot_date}:
        raise SchemaContractError(
            f"Fecha interna incompatible: esperada={snapshot_date}, encontradas={sorted(roots)}"
        )
    names = [Path(member.filename).name.lower() for member in packages]
    if len(names) != len(set(names)):
        raise SchemaContractError("El ZIP exterior contiene paquetes duplicados.")
    return sorted(packages, key=lambda item: item.filename)


def _active_snapshot(connection: duckdb.DuckDBPyConnection, snapshot_date: str):
    return connection.execute(
        "SELECT active_ingest_run_id, raw_sha256 FROM snapshot_state WHERE snapshot_date = ?",
        [snapshot_date],
    ).fetchone()


def ingest_snapshot(
    connection: duckdb.DuckDBPyConnection,
    outer_path: Path,
    force: bool = False,
) -> UUID | None:
    snapshot_date = outer_path.parent.name
    date.fromisoformat(snapshot_date)
    source_hash = file_sha256(outer_path)
    connection.execute(
        """
        UPDATE pipeline_runs
        SET status = 'interrupted', finished_at = CURRENT_TIMESTAMP,
            details = 'Proceso anterior finalizado sin activar el snapshot.'
        WHERE stage = 'ingest' AND snapshot_date = ? AND status = 'running'
        """,
        [snapshot_date],
    )
    active = _active_snapshot(connection, snapshot_date)
    if active and active[1] == source_hash and not force:
        print(f"[ingest] Fecha y hash ya procesados: {snapshot_date}")
        return None
    if active and active[1] != source_hash and not force:
        raise ValueError(
            f"La fecha {snapshot_date} ya existe con otro hash. Usa --force para reemplazarla."
        )

    run_id = uuid4()
    started_at = datetime.now(UTC)
    connection.execute(
        """
        INSERT INTO pipeline_runs (
            run_id, stage, snapshot_date, status, force, source_sha256, started_at, details
        ) VALUES (?, 'ingest', ?, 'running', ?, ?, ?, ?)
        """,
        [str(run_id), snapshot_date, force, source_hash, started_at, outer_path.name],
    )

    work_dir = INTERIM_DIR / snapshot_date / str(run_id)
    work_dir.mkdir(parents=True, exist_ok=True)
    warnings = 0
    package_count = 0
    try:
        connection.execute("BEGIN TRANSACTION")
        connection.execute("DELETE FROM commerce_snapshot WHERE snapshot_date = ?", [snapshot_date])
        connection.execute("DELETE FROM store_snapshot WHERE snapshot_date = ?", [snapshot_date])
        connection.execute("DELETE FROM fact_price WHERE snapshot_date = ?", [snapshot_date])

        with zipfile.ZipFile(outer_path) as outer:
            packages = _validate_outer(outer, snapshot_date)
            for member in packages:
                loaded_package, package_warnings = _ingest_package(
                    connection, outer, member, snapshot_date, work_dir, run_id
                )
                package_count += loaded_package
                warnings += package_warnings

        if package_count == 0:
            raise SchemaContractError("No se cargo ningun paquete no vacio.")
        price_rows = connection.execute(
            "SELECT COUNT(*) FROM fact_price WHERE ingest_run_id = ?", [str(run_id)]
        ).fetchone()[0]
        if price_rows == 0:
            raise SchemaContractError("El snapshot no contiene precios cargados.")

        warnings += connection.execute(
            """
            SELECT COUNT(*) FROM fact_price
            WHERE ingest_run_id = ? AND (
                id_comercio IS NULL OR id_bandera IS NULL OR
                id_sucursal IS NULL OR id_producto IS NULL
            )
            """,
            [str(run_id)],
        ).fetchone()[0]
        connection.execute("DELETE FROM snapshot_state WHERE snapshot_date = ?", [snapshot_date])
        connection.execute(
            """
            INSERT INTO snapshot_state (
                snapshot_date, active_ingest_run_id, raw_sha256, source_path,
                source_bytes, package_count, warning_count, activated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            """,
            [
                snapshot_date,
                str(run_id),
                source_hash,
                str(outer_path.resolve()),
                outer_path.stat().st_size,
                package_count,
                warnings,
            ],
        )
        connection.execute(
            """
            UPDATE pipeline_runs
            SET status = 'success', finished_at = CURRENT_TIMESTAMP, warning_count = ?
            WHERE run_id = ?
            """,
            [warnings, str(run_id)],
        )
        connection.execute("COMMIT")
        return run_id
    except Exception as error:
        with suppress(duckdb.TransactionException):
            connection.execute("ROLLBACK")
        connection.execute(
            """
            UPDATE pipeline_runs
            SET status = 'failed', finished_at = CURRENT_TIMESTAMP,
                error_count = 1, details = ?
            WHERE run_id = ?
            """,
            [f"{outer_path.name}: {error}", str(run_id)],
        )
        raise
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def ingest_all(
    force: bool = False,
    as_of: date | None = None,
    only_snapshot: date | None = None,
    database_path: Path = DATABASE_PATH,
) -> None:
    archives = sorted(RAW_DIR.glob("20??-??-??/sepa_*.zip"))
    if not archives:
        raise FileNotFoundError("No hay snapshots descargados en data/raw.")

    grouped: dict[date, list[Path]] = {}
    for archive in archives:
        snapshot = date.fromisoformat(archive.parent.name)
        if as_of and snapshot > as_of:
            continue
        if only_snapshot and snapshot != only_snapshot:
            continue
        grouped.setdefault(snapshot, []).append(archive)
    if not grouped:
        filters = []
        if as_of:
            filters.append(f"as_of={as_of}")
        if only_snapshot:
            filters.append(f"only_snapshot={only_snapshot}")
        description = ", ".join(filters) or "los filtros solicitados"
        raise FileNotFoundError(f"No hay snapshots que cumplan {description}.")
    for snapshot, paths in grouped.items():
        if len(paths) != 1:
            raise ValueError(f"Se esperaba un ZIP para {snapshot} y se encontraron {len(paths)}")

    connection = connect(database_path=database_path)
    try:
        for snapshot in sorted(grouped):
            ingest_snapshot(connection, grouped[snapshot][0], force=force)
        connection.execute("CHECKPOINT")
    finally:
        connection.close()
