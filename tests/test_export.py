from datetime import date

import pytest

import pricing_canasta.export as export_module
import pricing_canasta.validate as validate_module
from pricing_canasta.build import build_analytics
from pricing_canasta.export import _excel_value, export_all
from pricing_canasta.ingest import connect, ingest_snapshot


@pytest.mark.parametrize("prefix", ["=", "+", "-", "@"])
def test_excel_value_neutralizes_formula_prefixes(prefix):
    value = prefix + "SUM(A1:A2)"
    assert _excel_value(value) == "'" + value


def test_excel_value_preserves_numeric_and_safe_string_cells():
    assert _excel_value(-12.5) == -12.5
    assert _excel_value(7) == 7
    assert _excel_value("safe text") == "safe text"


def test_export_generates_excel_dashboards_parquet_and_report(fixture_raw, tmp_path, monkeypatch):
    _, archives = fixture_raw
    database = tmp_path / "export.duckdb"
    connection = connect(database_path=database, interim_dir=tmp_path / "interim")
    try:
        for archive in archives:
            ingest_snapshot(connection, archive)
    finally:
        connection.close()
    build_analytics(as_of=date(2026, 8, 2), database_path=database)

    output_dir = tmp_path / "outputs"
    export_dir = tmp_path / "exports"
    portfolio_dir = tmp_path / "portfolio"
    site_dir = tmp_path / "site"
    for directory in (output_dir, export_dir, portfolio_dir, site_dir):
        directory.mkdir()
    monkeypatch.setattr(export_module, "OUTPUT_DIR", output_dir)
    monkeypatch.setattr(export_module, "EXPORT_DIR", export_dir)
    monkeypatch.setattr(export_module, "PORTFOLIO_DATA_DIR", portfolio_dir)
    monkeypatch.setattr(export_module, "SITE_DIR", site_dir)
    monkeypatch.setattr(validate_module, "OUTPUT_DIR", output_dir)

    for stale_name in export_module.LEGACY_EXPORT_FILES:
        (portfolio_dir / f"{stale_name}.csv").write_text("legacy", encoding="utf-8")

    export_all(database_path=database)

    assert (output_dir / "pricing_canasta_supermercado.xlsx").stat().st_size > 0
    assert (output_dir / "dashboard_pricing_canasta.html").stat().st_size > 0
    assert (output_dir / "dashboard_mobile.html").stat().st_size > 0
    assert (site_dir / "index.html").stat().st_size > 0
    assert (site_dir / "mobile.html").stat().st_size > 0
    assert (output_dir / "resumen_ejecutivo.md").stat().st_size > 0
    summary = (output_dir / "resumen_ejecutivo.md").read_text(encoding="utf-8").lower()
    assert "nan%" not in summary
    assert "none" not in summary
    assert (output_dir / "validation_report.md").stat().st_size > 0
    assert (export_dir / "price_product_daily.parquet").stat().st_size > 0
    assert (portfolio_dir / "index_daily.csv").stat().st_size > 0
    assert (portfolio_dir / "dispersion_product_sample.csv").stat().st_size > 0
    assert (portfolio_dir / "price_anomalies_sample.csv").stat().st_size > 0
    assert all(
        not (portfolio_dir / f"{name}.csv").exists() for name in export_module.LEGACY_EXPORT_FILES
    )
    mobile = (output_dir / "dashboard_mobile.html").read_text(encoding="utf-8")
    assert '<meta name="viewport"' in mobile
    assert '<html lang="es">' in mobile
    assert "ultimo dia comparable" in mobile.lower()
