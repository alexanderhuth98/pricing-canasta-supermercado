# Entregables generados

`pricing-canasta export` regenera este directorio desde el build publicado.

| Archivo | Uso |
|---|---|
| `pricing_canasta_supermercado.xlsx` | Libro operativo con hojas agregadas. |
| `dashboard_pricing_canasta.html` | Dashboard interactivo de escritorio. |
| `dashboard_mobile.html` | Variante responsive de una columna. |
| `resumen_ejecutivo.md` | Hallazgos y limitaciones del corte. |
| `validation_report.md` | Quality checks, linaje y confianza. |
| `run_metadata.json` | Build, fecha UTC de generacion y nombres de artefactos. |

No editar estos entregables manualmente: cualquier cambio persistente debe implementarse
en `src/pricing_canasta/export.py` o `src/pricing_canasta/validate.py` y luego regenerarse.
