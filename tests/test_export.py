from datetime import date

import pandas as pd
import pytest

import pricing_canasta.export as export_module
import pricing_canasta.validate as validate_module
from pricing_canasta.build import build_analytics
from pricing_canasta.export import _excel_value, export_all
from pricing_canasta.ingest import connect, ingest_snapshot
from pricing_canasta.validate import ValidationResult


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
    assert '<html lang="es-AR">' in mobile
    assert "último día comparable" in mobile.lower()


def _dashboard_frames(dispersion: pd.DataFrame) -> dict[str, pd.DataFrame]:
    return {
        "index_daily": pd.DataFrame(
            [
                {
                    "publishable": True,
                    "snapshot_date": pd.Timestamp("2026-08-02"),
                    "common_gtins": 125,
                    "banner_label": "Cadena A",
                    "price_index": 99.5,
                }
            ]
        ),
        "basket_banner": pd.DataFrame(
            columns=[
                "snapshot_date",
                "coverage_status",
                "branch_median_cost",
                "banner_label",
                "complete_stores",
                "completion_rate",
            ]
        ),
        "dispersion_entity": dispersion,
        "source_health": pd.DataFrame(
            [
                {
                    "snapshot_date": pd.Timestamp("2026-08-02"),
                    "store_coverage_ratio": 1.0,
                    "reporting_stores": 20,
                    "source_healthy": True,
                }
            ]
        ),
        "index_sensitivity": pd.DataFrame(
            [
                {
                    "snapshot_date": pd.Timestamp("2026-08-02"),
                    "banner_label": "Cadena A",
                    "raw_index": 99.5,
                    "exclude_critical_index": 99.4,
                    "sensitivity_delta": 0.1,
                }
            ]
        ),
        "banner_health": pd.DataFrame([{"source_healthy": True}]),
        "basket_savings": pd.DataFrame(columns=["snapshot_date", "comparison_level"]),
    }


def _validation(tmp_path) -> ValidationResult:
    return ValidationResult(
        build_id="12345678-1234-1234-1234-123456789abc",
        as_of_date=date(2026, 8, 2),
        confidence="Alta",
        high_failures=0,
        medium_failures=0,
        report_path=tmp_path / "validation_report.md",
    )


def test_dispersion_uses_latest_publishable_date_per_level_and_keeps_empty_state():
    frame = pd.DataFrame(
        [
            {
                "snapshot_date": pd.Timestamp("2026-08-01"),
                "dispersion_level": "BANNER",
                "coverage_status": "PUBLISHABLE",
            },
            {
                "snapshot_date": pd.Timestamp("2026-08-02"),
                "dispersion_level": "BANNER",
                "coverage_status": "SUPPRESSED",
            },
            {
                "snapshot_date": pd.Timestamp("2026-08-02"),
                "dispersion_level": "PROVINCE",
                "coverage_status": "PUBLISHABLE",
            },
        ]
    )

    chain = export_module._latest_publishable_level(frame, "BANNER")
    province = export_module._latest_publishable_level(frame, "PROVINCE")
    missing = export_module._latest_publishable_level(frame, "BANNER_PROVINCE")

    assert chain["snapshot_date"].unique().tolist() == [pd.Timestamp("2026-08-01")]
    assert province["snapshot_date"].unique().tolist() == [pd.Timestamp("2026-08-02")]
    assert missing.empty
    chain_title, chain_notice = export_module._dispersion_panel_text(
        "Dispersión por cadena", chain, date(2026, 8, 2)
    )
    missing_title, missing_notice = export_module._dispersion_panel_text(
        "Dispersión cadena-provincia", missing, date(2026, 8, 2)
    )
    assert "dato efectivo 01/08/2026" in chain_title
    assert "El corte global del 02/08/2026 no tuvo cobertura publicable" in chain_notice
    assert missing_title.endswith("sin dato publicable")
    assert missing_notice.endswith("sin dato publicable en la ventana observada.")


def test_dashboard_identity_zoom_reset_dates_and_self_contained_site(tmp_path, monkeypatch):
    dispersion = pd.DataFrame(
        [
            {
                "snapshot_date": pd.Timestamp("2026-08-01"),
                "dispersion_level": "BANNER",
                "coverage_status": "PUBLISHABLE",
                "median_dispersion_clean": 0.2,
                "banner_label": "Cadena A",
                "provincia_codigo": None,
                "publishable_products": 40,
            },
            {
                "snapshot_date": pd.Timestamp("2026-08-02"),
                "dispersion_level": "BANNER",
                "coverage_status": "SUPPRESSED",
                "median_dispersion_clean": 0.8,
                "banner_label": "Cadena B",
                "provincia_codigo": None,
                "publishable_products": 8,
            },
            {
                "snapshot_date": pd.Timestamp("2026-08-02"),
                "dispersion_level": "PROVINCE",
                "coverage_status": "PUBLISHABLE",
                "median_dispersion_clean": 0.3,
                "banner_label": None,
                "provincia_codigo": "AR-C",
                "publishable_products": 45,
            },
        ]
    )
    frames = _dashboard_frames(dispersion)
    output_dir = tmp_path / "outputs"
    site_dir = tmp_path / "site"
    output_dir.mkdir()
    site_dir.mkdir()
    monkeypatch.setattr(export_module, "OUTPUT_DIR", output_dir)
    monkeypatch.setattr(export_module, "SITE_DIR", site_dir)

    export_module._write_dashboard(frames, _validation(tmp_path))
    export_module._write_executive_summary(frames, _validation(tmp_path))

    html = (site_dir / "index.html").read_text(encoding="utf-8")
    summary = (output_dir / "resumen_ejecutivo.md").read_text(encoding="utf-8")
    assert "Dispersión por cadena: dato efectivo 01/08/2026." in html
    assert "El corte global del 02/08/2026 no tuvo cobertura publicable" in html
    assert "Dispersión por provincia: dato efectivo 02/08/2026." in html
    assert "Dispersión cadena-provincia: sin dato publicable" in summary
    assert "Dispersión por cadena: dato efectivo 01/08/2026." in summary
    assert "--bg:#0b1111" in html
    assert "--surface-raised:#1b2223" in html
    assert "--mint:#9ef6e5" in html
    assert "rgba(158,246,229,.11)" in html
    assert "Space Grotesk" in html
    assert "IBM Plex Mono" in html
    assert "https://alexanderhuth98.github.io/#proyectos" in html
    assert "Restablecer vista" in html
    assert "Plotly.relayout(graph, update)" in html
    assert '"displaylogo": false' in html
    assert '"scrollZoom": false' in html
    assert '"doubleClick": "reset+autosize"' in html
    assert '"locale": "es"' in html
    assert "Restablecer ejes" in html
    assert "zoom2d" in html
    assert "pan2d" in html
    assert "autoScale2d" in html
    assert "resetScale2d" in html
    assert 'src="https://cdn.plot.ly' not in html
