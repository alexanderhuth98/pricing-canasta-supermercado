import json
import os
import re
import unicodedata
import zipfile
from datetime import UTC, date, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .config import CATALOG_URL, MANIFEST_DIR, RAW_DIR, ensure_directories
from .ingest import file_sha256, validate_zip_safety

CHUNK_SIZE = 8 * 1024 * 1024
RETRY_STATUS = (408, 429, 500, 502, 503, 504)
MAX_HTTP_DOWNLOAD_BYTES = int(os.getenv("MAX_HTTP_DOWNLOAD_BYTES", str(8 * 1024**3)))
OFFICIAL_CATALOG_HOST = "datos.gob.ar"
OFFICIAL_RESOURCE_HOST = "datos.produccion.gob.ar"
OFFICIAL_DATASET_ID = "6f47ec76-d1ce-4e34-a7e1-621fe9b1d0b5"
OFFICIAL_SLOTS = frozenset(
    {"lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"}
)
RESOURCE_PATH_PATTERN = re.compile(
    rf"/dataset/{OFFICIAL_DATASET_ID}/resource/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/"
    r"download/sepa_([a-z]+)\.zip"
)


def _slug(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "_", ascii_value.lower()).strip("_")


def _session() -> requests.Session:
    retry = Retry(
        total=5,
        connect=5,
        read=5,
        status=5,
        backoff_factor=1,
        status_forcelist=RETRY_STATUS,
        allowed_methods=frozenset({"GET", "HEAD"}),
        respect_retry_after_header=True,
    )
    session = requests.Session()
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def _parsed_official_url(url: str, expected_host: str):
    parsed = urlsplit(url)
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError(f"URL oficial invalida: {url}") from error
    if (
        parsed.scheme != "https"
        or parsed.hostname != expected_host
        or port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise ValueError(f"URL fuera de la fuente oficial permitida: {url}")
    return parsed


def _validate_catalog_url(url: str) -> None:
    parsed = _parsed_official_url(url, OFFICIAL_CATALOG_HOST)
    if parsed.path != "/api/3/action/package_show" or parse_qs(
        parsed.query, strict_parsing=True
    ) != {"id": ["precios-claros-base-sepa"]}:
        raise ValueError(f"Recurso de catalogo no permitido: {url}")


def _validate_resource_url(url: str, weekday: str) -> None:
    parsed = _parsed_official_url(url, OFFICIAL_RESOURCE_HOST)
    match = RESOURCE_PATH_PATTERN.fullmatch(parsed.path)
    if parsed.query or not match or weekday not in OFFICIAL_SLOTS or match.group(1) != weekday:
        raise ValueError(f"Recurso ZIP oficial no permitido: {url}")


def _reject_redirect(response: requests.Response) -> None:
    status_code = getattr(response, "status_code", 200)
    if 300 <= status_code < 400:
        raise ValueError("La fuente oficial respondio con una redireccion no permitida.")


def _content_length(headers: requests.structures.CaseInsensitiveDict) -> int | None:
    value = headers.get("Content-Length")
    if value is None:
        return None
    try:
        length = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"Content-Length invalido: {value}") from error
    if length < 0:
        raise ValueError(f"Content-Length invalido: {value}")
    if length > MAX_HTTP_DOWNLOAD_BYTES:
        raise ValueError(
            f"Descarga excede MAX_HTTP_DOWNLOAD_BYTES={MAX_HTTP_DOWNLOAD_BYTES}: {length}"
        )
    return length


def _load_manifest(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8") as file:
        return [json.loads(line) for line in file if line.strip()]


def _write_manifest_atomic(path: Path, entries: list[dict]) -> None:
    temporary = path.with_suffix(path.suffix + f".{uuid4().hex}.tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as file:
        for entry in entries:
            file.write(json.dumps(entry, ensure_ascii=False, sort_keys=True) + "\n")
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def _validate_zip(path: Path) -> str:
    with zipfile.ZipFile(path) as archive:
        validate_zip_safety(archive, path.name)
        members = [
            member for member in archive.infolist() if member.filename.lower().endswith(".zip")
        ]
        if not members:
            raise ValueError(f"{path.name} no contiene paquetes interiores.")
        roots = {Path(member.filename).parts[0] for member in members}
        if len(roots) != 1:
            raise ValueError(f"{path.name} contiene multiples fechas internas: {roots}")
        snapshot = next(iter(roots))
        date.fromisoformat(snapshot)
        if archive.testzip() is not None:
            raise zipfile.BadZipFile(f"CRC invalido en {path.name}")
        return snapshot


def _remote_unchanged(entry: dict, headers: requests.structures.CaseInsensitiveDict) -> bool:
    etag = headers.get("ETag")
    if etag and entry.get("etag"):
        return etag == entry["etag"]
    last_modified = headers.get("Last-Modified")
    content_length = headers.get("Content-Length")
    return bool(
        last_modified
        and entry.get("last_modified") == last_modified
        and (not content_length or int(content_length) == int(entry.get("bytes", -1)))
    )


def _verified_local_entry(entry: dict) -> bool:
    path = Path(entry.get("path", ""))
    if not path.exists() or path.stat().st_size != int(entry.get("bytes", -1)):
        return False
    return file_sha256(path) == entry.get("sha256")


def _download_resource(resource: dict, known: list[dict]) -> dict:
    url = resource["url"]
    weekday = _slug(resource["name"])
    _validate_resource_url(url, weekday)
    landing_dir = RAW_DIR / "_landing"
    landing_dir.mkdir(parents=True, exist_ok=True)
    temporary_path = landing_dir / f"sepa_{weekday}.{uuid4().hex}.zip.part"

    try:
        with _session() as session:
            head = session.head(url, allow_redirects=False, timeout=(10, 60))
            _reject_redirect(head)
            head.raise_for_status()
            _content_length(head.headers)
            existing = next((entry for entry in reversed(known) if entry.get("url") == url), None)
            if (
                existing
                and _remote_unchanged(existing, head.headers)
                and _verified_local_entry(existing)
            ):
                print(f"[download] Sin cambios y hash verificado: {Path(existing['path']).name}")
                return {
                    **existing,
                    "last_checked_at_utc": datetime.now(UTC).isoformat(),
                    "status": "unchanged",
                }

            downloaded = 0
            expected_length = None
            with session.get(
                url, stream=True, allow_redirects=False, timeout=(10, 300)
            ) as response:
                _reject_redirect(response)
                response.raise_for_status()
                expected_length = _content_length(response.headers)
                with temporary_path.open("wb") as output:
                    for chunk in response.iter_content(CHUNK_SIZE):
                        if not chunk:
                            continue
                        if downloaded + len(chunk) > MAX_HTTP_DOWNLOAD_BYTES:
                            raise ValueError(
                                f"Descarga excede MAX_HTTP_DOWNLOAD_BYTES={MAX_HTTP_DOWNLOAD_BYTES}"
                            )
                        output.write(chunk)
                        downloaded += len(chunk)
                        if downloaded // (128 * 1024 * 1024) != (downloaded - len(chunk)) // (
                            128 * 1024 * 1024
                        ):
                            print(f"[download] {weekday}: {downloaded / 1024**2:,.0f} MiB")
                    output.flush()
                    os.fsync(output.fileno())

            if expected_length is not None and downloaded != expected_length:
                raise OSError(
                    f"Descarga incompleta para {weekday}: "
                    f"esperados={expected_length}, bytes={downloaded}"
                )
            snapshot_date = _validate_zip(temporary_path)
            new_hash = file_sha256(temporary_path)
            destination_dir = RAW_DIR / snapshot_date
            destination_dir.mkdir(parents=True, exist_ok=True)
            destination = destination_dir / f"sepa_{weekday}.zip"

            status = "downloaded"
            if destination.exists():
                if file_sha256(destination) != new_hash:
                    raise FileExistsError(
                        f"Ya existe {destination} con otro hash; el raw es inmutable."
                    )
                status = "deduplicated"
            else:
                os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)

    return {
        "downloaded_at_utc": datetime.now(UTC).isoformat(),
        "last_checked_at_utc": datetime.now(UTC).isoformat(),
        "snapshot_date": snapshot_date,
        "weekday_slot": resource["name"],
        "resource_id": resource.get("id"),
        "url": url,
        "etag": head.headers.get("ETag"),
        "last_modified": head.headers.get("Last-Modified"),
        "bytes": destination.stat().st_size,
        "sha256": new_hash,
        "zip_validated": True,
        "path": str(destination.resolve()),
        "status": status,
    }


def download_all() -> list[dict]:
    ensure_directories()
    manifest_path = MANIFEST_DIR / "downloads.jsonl"
    known = _load_manifest(manifest_path)

    _validate_catalog_url(CATALOG_URL)
    with _session() as session:
        response = session.get(CATALOG_URL, allow_redirects=False, timeout=(10, 60))
        _reject_redirect(response)
        response.raise_for_status()
        catalog = response.json()
    if not catalog.get("success"):
        raise RuntimeError("El catalogo oficial respondio success=false")
    resources = [
        item for item in catalog["result"]["resources"] if item.get("format", "").upper() == "ZIP"
    ]
    if len(resources) != 7:
        raise ValueError(f"Se esperaban 7 snapshots ZIP y se encontraron {len(resources)}")
    slots = [_slug(resource["name"]) for resource in resources]
    if len(slots) != len(set(slots)):
        raise ValueError(f"El catalogo contiene slots diarios duplicados: {slots}")

    results = []
    updated = list(known)
    for resource in resources:
        result = _download_resource(resource, updated)
        results.append(result)
        if result["status"] in ("downloaded", "deduplicated"):
            updated.append(result)
        elif result["status"] == "unchanged":
            for index in range(len(updated) - 1, -1, -1):
                if updated[index].get("url") == result.get("url"):
                    updated[index] = result
                    break
    _write_manifest_atomic(manifest_path, updated)
    return results
