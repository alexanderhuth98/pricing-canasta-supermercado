# Publicación de entregables

El repositorio mantiene el historial orientado a código y revisión. Los binarios y
artefactos offline se publican como activos de una versión, no como blobs Git.

## Activos de la versión `v2.0.0`

- `powerbi/PricingCanasta.pbix`
- `outputs/pricing_canasta_supermercado.xlsx`
- `outputs/dashboard_pricing_canasta.html`
- `outputs/dashboard_mobile.html`

Estos archivos se conservan localmente e ignorados. Antes de crear el Release:

1. Ejecutar `uv run pricing-canasta export`.
2. Regenerar PBIP, actualizar datos en Desktop y guardar el PBIX.
3. Reconciliar los KPI con `reports/2026-08-02/validation_report.md`.
4. Abrir ambos HTML y el Excel.
5. Ejecutar el empaquetador desde la raíz:

   ```powershell
   .\scripts\package_release.ps1
   ```

   Si la política local exige scripts firmados:

   ```cmd
   type scripts\package_release.ps1 | powershell.exe -NoProfile -Command -
   ```

6. Verificar `outputs/release-v2.0.0/SHA256SUMS.txt`.
7. Crear un Release desde el commit etiquetado y adjuntar los cuatro archivos y sus hashes.

El dashboard web liviano se publica desde `site/` mediante GitHub Pages. Usa Plotly CDN;
los HTML del Release incluyen Plotly para funcionar sin conexión.

## Controles previos

```powershell
uv run ruff check src tests
uv run pytest --cov=pricing_canasta --cov-fail-under=80
git diff --check
git status --short --ignored
```

No adjuntar raw, DuckDB, Parquet, `.pbi/`, temporales ni muestras de anomalías por
sucursal.
