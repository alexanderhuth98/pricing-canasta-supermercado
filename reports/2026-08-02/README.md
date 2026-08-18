# Snapshot de publicación: 2026-08-02

Este directorio conserva una copia Markdown identificable de los informes generados
para el corte analítico `2026-08-02`. A diferencia de `outputs/`, que se regenera y usa
nombres estables, estos archivos representan el estado publicado indicado abajo.

| Campo | Valor |
|---|---|
| Fecha de corte (`as_of`) | `2026-08-02` |
| Ventana | `2026-07-27` a `2026-08-02` |
| Build | `941da9b2-93b6-40b8-8de8-c9e27ad03e10` |
| Esquema | `2.0.0` |
| Generación del informe de validación | `2026-08-15T03:32:18.884215+00:00` |
| Confianza | `Media` |

## Archivos

- [`resumen_ejecutivo.md`](resumen_ejecutivo.md): hallazgos, acciones y limitaciones del corte.
- [`validation_report.md`](validation_report.md): métricas de build, quality gates,
  linaje y confianza.

Las cifras se preservan desde `outputs/resumen_ejecutivo.md` y
`outputs/validation_report.md` para el build identificado. El snapshot no contiene los
ZIP raw ni el warehouse.

Los hashes de los siete inputs constan en `manifests/raw_sources.jsonl`, pero el
manifiesto no es un archivo de datos. Una reconstrucción histórica completa desde un
clon nuevo requiere copias inmutables de esos inputs exactos; este repositorio no afirma
que exista un archivo durable. Las pruebas y la verificación de resultados agregados
versionados siguen siendo reproducibles según [`docs/data_access.md`](../../docs/data_access.md).

Los datos y métricas derivados de Precios Claros - Base SEPA se reutilizan bajo CC BY
4.0; consulte [`DATA_LICENSE.md`](../../DATA_LICENSE.md).
