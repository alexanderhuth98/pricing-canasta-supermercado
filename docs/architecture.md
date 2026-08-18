# Arquitectura

```text
API oficial
    |
    v
7 ZIP rotativos -> hash SHA-256 + manifiesto -> archivo raw fechado fuera de Git
    |
    v
ZIP por comercio -> contrato de esquema + saneamiento auditable -> DuckDB
    |
    +-- snapshot_state + pipeline_runs
    +-- commerce_snapshot + store_snapshot
    +-- fact_price (fuente completa)
    |
    v
marts de calidad, cobertura, indice, dispersion y canasta
    |
    +-- CSV/Parquet agregados para Power BI
    |       +-- PBIP/PBIR + model.bim reproducibles
    |       +-- PBIX validado en Power BI Desktop
    +-- Excel operativo
    +-- dashboard HTML
    +-- resumen ejecutivo
```

## Elecciones técnicas

- **DuckDB** permite procesar cerca de 100 millones de filas sin un servidor externo.
- Los CSV expandidos son temporales; se conservan los ZIP y la base analítica.
- Los identificadores se tratan como texto para conservar ceros iniciales.
- El GTIN se completa a 14 dígitos y se valida mediante su dígito verificador.
- Cada snapshot se ingiere en una transacción y se activa sólo después de reconciliar filas.
- Cada build fija siete `ingest_run_id`, crea todos los marts en una transacción, ejecuta
  quality gates y recién entonces actualiza `warehouse_state`.
- `GLOBAL_GTIN` es el único alcance comparable entre comercios. `RESTRICTED_LOCAL` e
  `INTERNAL_LOCAL` conservan análisis dentro de comercio/bandera sin cruces inválidos.
- El índice usa siete banderas predefinidas, intersección diaria de GTIN, benchmark
  geométrico entre cadenas e igual peso por producto y cadena. Se publican al menos 500 GTIN.
- La canasta v1 fija ocho GTIN y exige evidencia semántica y de presentación en variantes
  observadas. No se cambia automáticamente por cobertura.

## Granularidad

`fact_price` contiene una observación por:

```text
fecha + comercio + bandera + sucursal + producto declarado
```

El build verifica que el grano global comparable sea único antes de proyectarlo. Si aparece
un duplicado, el build falla y conserva la publicación anterior. El hecho original permanece
disponible para auditoría y los códigos locales se agregan por su clave acotada.

## Rendimiento

- La descarga se realiza en bloques de 8 MiB.
- La ingestión procesa un comercio por vez.
- DuckDB usa cuatro hilos configurables mediante `DUCKDB_THREADS` y almacenamiento
  temporal bajo `data/interim/`. El hecho global se proyecta después de validar unicidad
  para evitar una agregación casi tan grande como la fuente.
- Las exportaciones para BI son agregadas; Power BI no carga `fact_price` completa.
- `powerbi/build_pbip.ps1` construye un modelo Import con 14 tablas, una dimensión calendario,
  9 relaciones activas y 17 medidas. TOM valida `model.bim` antes de abrir Desktop.
- El reporte PBIR contiene cuatro páginas y 26 visuales. El PBIX se guarda en Desktop porque
  Microsoft no ofrece una conversión PBIP-PBIX headless oficial.
- Las medidas de dispersión seleccionan el último `snapshot_date` que tenga filas
  `PUBLISHABLE`; no confunden el último día calendario con el último día defendible.
