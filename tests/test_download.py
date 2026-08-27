import json
import zipfile
from pathlib import Path

import pytest
from requests.structures import CaseInsensitiveDict

from pricing_canasta.download import (
    _download_resource,
    _load_manifest,
    _remote_unchanged,
    _session,
    _slug,
    _validate_catalog_url,
    _validate_resource_url,
    _validate_zip,
    _verified_local_entry,
    _write_manifest_atomic,
)
from pricing_canasta.ingest import file_sha256

OFFICIAL_RESOURCE_URL = (
    "https://datos.produccion.gob.ar/dataset/"
    "6f47ec76-d1ce-4e34-a7e1-621fe9b1d0b5/resource/"
    "f8e75128-515a-436e-bf8d-5c63a62f2005/download/sepa_domingo.zip"
)


def test_local_file_must_match_size_and_streaming_hash(tmp_path):
    path = tmp_path / "source.zip"
    path.write_bytes(b"content")
    entry = {"path": str(path), "bytes": 7, "sha256": file_sha256(path)}
    assert _verified_local_entry(entry)
    path.write_bytes(b"changed")
    assert not _verified_local_entry(entry)


def test_etag_has_priority_over_last_modified():
    entry = {"etag": '"old"', "last_modified": "same", "bytes": 10}
    headers = CaseInsensitiveDict(
        {"ETag": '"new"', "Last-Modified": "same", "Content-Length": "10"}
    )
    assert not _remote_unchanged(entry, headers)


def test_manifest_replacement_is_parseable(tmp_path):
    path = tmp_path / "manifest.jsonl"
    entries = [{"sha256": "a", "bytes": 1}, {"sha256": "b", "bytes": 2}]
    _write_manifest_atomic(path, entries)
    parsed = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    assert parsed == entries
    assert _load_manifest(path) == entries
    assert _load_manifest(tmp_path / "missing.jsonl") == []


def test_slug_and_retry_session():
    assert _slug("Miércoles") == "miercoles"
    session = _session()
    assert session.get_adapter("https://").max_retries.total == 5
    session.close()


@pytest.mark.parametrize(
    "url",
    [
        "http://datos.produccion.gob.ar/dataset/file.zip",
        "https://evil.example/sepa_domingo.zip",
        "https://datos.produccion.gob.ar/otro/sepa_domingo.zip",
    ],
)
def test_resource_url_rejects_non_official_sources(url):
    with pytest.raises(ValueError, match="oficial|permitido"):
        _validate_resource_url(url, "domingo")


def test_catalog_and_resource_allowlists_accept_only_expected_resources():
    _validate_catalog_url(
        "https://datos.gob.ar/api/3/action/package_show?id=precios-claros-base-sepa"
    )
    _validate_resource_url(OFFICIAL_RESOURCE_URL, "domingo")
    with pytest.raises(ValueError, match="catalogo"):
        _validate_catalog_url("https://datos.gob.ar/api/3/action/package_show?id=otro-dataset")


def test_validate_zip_requires_one_date_and_valid_crc(tmp_path):
    valid = tmp_path / "valid.zip"
    with zipfile.ZipFile(valid, "w") as archive:
        archive.writestr("2026-08-02/package.zip", b"nested")
    assert _validate_zip(valid) == "2026-08-02"

    invalid = tmp_path / "invalid.zip"
    with zipfile.ZipFile(invalid, "w") as archive:
        archive.writestr("readme.txt", b"none")
    try:
        _validate_zip(invalid)
    except ValueError as error:
        assert "no contiene paquetes" in str(error)
    else:
        raise AssertionError("Debio rechazar un ZIP sin paquetes interiores")


class _FakeResponse:
    def __init__(self, content=b"", headers=None, payload=None, status_code=200):
        self.content = content
        self.headers = CaseInsensitiveDict(headers or {})
        self.payload = payload
        self.status_code = status_code

    def raise_for_status(self):
        return None

    def iter_content(self, _chunk_size):
        yield self.content

    def json(self):
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


class _FakeSession:
    def __init__(self, response):
        self.response = response

    def head(self, *_args, **_kwargs):
        return _FakeResponse(headers=self.response.headers)

    def get(self, *_args, **_kwargs):
        return self.response

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


def test_download_resource_streams_validates_and_reuses_hash(tmp_path, monkeypatch):
    import pricing_canasta.download as module

    source = tmp_path / "source.zip"
    with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("2026-08-02/package.zip", b"nested")
    content = source.read_bytes()
    response = _FakeResponse(
        content=content,
        headers={
            "ETag": '"fixture"',
            "Last-Modified": "Sun, 02 Aug 2026 10:00:00 GMT",
            "Content-Length": str(len(content)),
        },
    )
    monkeypatch.setattr(module, "RAW_DIR", tmp_path / "raw")
    monkeypatch.setattr(module, "_session", lambda: _FakeSession(response))
    resource = {"url": OFFICIAL_RESOURCE_URL, "name": "Domingo", "id": "x"}

    downloaded = _download_resource(resource, [])
    assert downloaded["status"] == "downloaded"
    assert downloaded["snapshot_date"] == "2026-08-02"
    assert Path(downloaded["path"]).exists()

    unchanged = _download_resource(resource, [downloaded])
    assert unchanged["status"] == "unchanged"


def test_download_failure_removes_partial_file(tmp_path, monkeypatch):
    import pricing_canasta.download as module

    response = _FakeResponse(
        content=b"not-a-zip",
        headers={"Content-Length": "9"},
    )
    monkeypatch.setattr(module, "RAW_DIR", tmp_path / "raw")
    monkeypatch.setattr(module, "_session", lambda: _FakeSession(response))
    resource = {"url": OFFICIAL_RESOURCE_URL, "name": "Domingo"}

    with pytest.raises(zipfile.BadZipFile):
        _download_resource(resource, [])
    assert list((tmp_path / "raw" / "_landing").glob("*.part")) == []


def test_download_rejects_stream_over_limit_and_removes_partial(tmp_path, monkeypatch):
    import pricing_canasta.download as module

    response = _FakeResponse(content=b"12345")
    monkeypatch.setattr(module, "RAW_DIR", tmp_path / "raw")
    monkeypatch.setattr(module, "MAX_HTTP_DOWNLOAD_BYTES", 4)
    monkeypatch.setattr(module, "_session", lambda: _FakeSession(response))

    with pytest.raises(ValueError, match="MAX_HTTP_DOWNLOAD_BYTES"):
        _download_resource({"url": OFFICIAL_RESOURCE_URL, "name": "Domingo"}, [])
    assert list((tmp_path / "raw" / "_landing").glob("*.part")) == []
