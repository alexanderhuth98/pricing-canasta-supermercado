# Supermarket pricing and comparable basket

[![CI](https://github.com/alexanderhuth98/pricing-canasta-supermercado/actions/workflows/ci.yml/badge.svg)](https://github.com/alexanderhuth98/pricing-canasta-supermercado/actions/workflows/ci.yml)
[![Dashboard](https://img.shields.io/badge/dashboard-GitHub%20Pages-0969da)](https://alexanderhuth98.github.io/pricing-canasta-supermercado/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[Versión en español](README.md)

End-to-end Data Analytics portfolio project built from Argentina's official
**Precios Claros - SEPA** national snapshots.

## Business question

Which supermarket banners and provinces show the largest price differences, and
what is the observed cost of an exactly comparable product basket during the latest
available week?

## Highlights

- 7 national daily snapshots from July 27 to August 2, 2026.
- 97,485,870 source price records loaded and reconciled with zero row loss.
- 94,553,421 comparable global-GTIN observations.
- Exact GTIN matching; products are never joined only by description.
- Restricted `20-29` and internal product codes remain in a separate local fact.
- List, general promotion and segmented promotion prices remain separate.
- Atomic snapshot ingestion and atomic mart publication with explicit lineage.
- Seven-banner common-product index using geometric means and equal product/banner weight.
- A fixed eight-GTIN basket with no promotion prices, substitution, or imputation.
- DuckDB marts, automated gates, Excel, desktop/mobile HTML dashboards, and a reproducible Power BI project.
- Editable PBIP and validated PBIX with 14 tables, 9 relationships, 17 measures, and four report pages.

The latest publishable index covers 634 common GTINs. Hipermercado Carrefour has the
lowest level (96.98) and Jumbo the highest (103.36). The observed basket gap between
the highest- and lowest-cost publishable banners is ARS 5,163 (15.1%). Confidence is
`Medium` because source-health and quality warnings remain; seven days also limit structural claims.

## Power BI report

![Power BI executive overview](docs/images/powerbi_panorama.png)

![Power BI quality and coverage](docs/images/powerbi_calidad.png)

The report imports only aggregated CSV files from `portfolio_data/`. The August 2
dispersion cut is entirely `SUPPRESSED`, so dispersion cards deliberately use the latest
date containing `PUBLISHABLE` entities: July 31. The resulting clean median dispersion is
3.4%, covering 29,812 product-entity counts. Suppressed rows are never converted to
zero or included in rankings.

The 95.9% banner-day health figure covers the full week (47/49). The Power BI card shows
85.7% for the latest cut only (6/7 healthy banners).

Open `powerbi/PricingCanasta.pbip` for the editable project. Rebuild and validation
instructions are available in `powerbi/README.md`; the validated PBIX is distributed as
a GitHub Release asset rather than stored in Git history.

## Run

```powershell
uv sync --extra dev --locked
uv run pytest -q
uv run pricing-canasta --help
```

Tests and the published aggregates are reproducible from a clean clone. Rebuilding the
historical July 27-August 2 cut additionally requires the seven immutable raw ZIP files
whose hashes are listed in `manifests/raw_sources.jsonl`; the official catalog rotates
its resources and is not a historical archive.

Raw ZIP files, intermediates and the DuckDB warehouse are excluded from Git. Curated
aggregates live in `portfolio_data/`, reports in `reports/2026-08-02/`, the web dashboard
in `site/`, and PBIX/XLSX/offline HTML files are distributed as GitHub Release assets.

## Quality and CI

The repository includes 60 tests and enforces at least 80% coverage. GitHub Actions and
`.gitlab-ci.yml` use the locked environment for Ruff, pytest and dependency auditing;
GitHub additionally checks local links, scans history for secrets and validates the
versioned PBIP structure. Run `powerbi/validate_pbip.ps1` locally for static checks plus
TOM deserialization with Power BI Desktop.

## Limitations

- Seven days are insufficient to estimate inflation.
- Prices are submitted by retailers and may include missing or stale packages.
- Missing basket components are not imputed.
- The relative price index is descriptive and is not weighted by consumption.
- National values describe the observed store network and are not population-weighted.
- The latest calendar date is not automatically the latest publishable date for every metric.
