# Documentación técnica completa y runbook operativo

## 1. Propósito del documento

Este documento explica de extremo a extremo cómo funciona el proyecto
`pricing_canasta_supermercado`. Está dirigido a una persona que no participó en su
desarrollo y necesita:

- entender el objetivo de negocio y las decisiones metodológicas;
- instalar y ejecutar el proyecto;
- identificar qué tabla contiene cada dato;
- conocer el grano, entradas, transformaciones y consumidores de cada tabla;
- verificar que una publicación sea consistente;
- diagnosticar una descarga, ingestión, build, validación o exportación fallida;
- recuperar el sistema sin perder la última publicación válida;
- modificar el modelo sin romper comparabilidad, linaje o reproducibilidad.

Las secciones de diseño describen el comportamiento esperado del código. La sección
"Estado observado" describe un corte concreto y puede quedar desactualizada cuando se
incorporen snapshots o se publique otro build.

## 2. Resumen ejecutivo del sistema

El proyecto procesa los snapshots nacionales de **Precios Claros - Base SEPA** y crea
un warehouse DuckDB con análisis de:

- calidad y cobertura de la fuente;
- nivel relativo de precios entre siete cadenas;
- persistencia y solapamiento de productos;
- dispersión de precios nacional, por cadena y por provincia;
- costo de una canasta fija de ocho GTIN exactamente comparables;
- anomalías transversales y saltos temporales de precio.

Los principios centrales son:

1. Un producto sólo se compara globalmente si su código es un GTIN válido.
2. Los códigos internos y restringidos `20-29` se conservan, pero no se cruzan entre comercios.
3. Lista, promoción general y promoción segmentada permanecen separadas.
4. El índice usa el mismo panel de GTIN en todas las cadenas de un día.
5. La canasta usa ocho GTIN fijos y no imputa productos faltantes.
6. Los rankings sólo deben usar resultados que superen sus gates de cobertura.
7. La ingestión publica por snapshot y el build publica todos los marts en una transacción.
8. Una falla nunca debe reemplazar el último snapshot o build válido.

## 3. Estado observado de referencia

Estado comprobado al finalizar la implementación de versión 2:

| Concepto | Valor |
|---|---|
| Base operativa | `pricing_v2_strict.duckdb` |
| Versión de esquema | `2.0.0` |
| Build publicado | `941da9b2-93b6-40b8-8de8-c9e27ad03e10` |
| Ventana | 2026-07-27 a 2026-08-02 |
| Snapshots activos | 7 |
| Filas de precios fuente | 97.485.870 |
| Filas `GLOBAL_GTIN` | 94.553.421 |
| Filas `RESTRICTED_LOCAL` | 2.729.439 |
| Líneas físicas reconstruidas | 560 |
| Gates altos fallidos | 0 |
| Salud cadena-día | 47/49 |
| Confianza | Media |

Los runs fallidos o interrumpidos permanecen en `pipeline_runs` como historial auditable.
No son trabajo pendiente si existe un run posterior exitoso y no quedan filas `running`.

## 4. Arquitectura general

```text
Catálogo oficial CKAN
        |
        v
7 recursos ZIP nacionales
        |
        v
data/raw/<fecha>/sepa_<slot>.zip
        |
        +--> SHA-256 + manifiesto
        |
        v
ZIP interiores por comercio
        |
        v
contrato CSV + saneamiento temporal
        |
        v
commerce_snapshot / store_snapshot / fact_price
        |
        v
snapshot_state selecciona versión activa por fecha
        |
        v
build_inputs fija siete runs y hashes exactos
        |
        v
35 tablas analíticas + quality_checks
        |
        v
warehouse_state publica un único build
        |
        +--> CSV / Parquet
        +--> Excel
        +--> dashboards HTML
        +--> resumen ejecutivo
        +--> informe de validación
        +--> datasets para Power BI
```

Puntos de entrada del código:

| Archivo | Responsabilidad |
|---|---|
| `src/pricing_canasta/config.py` | Rutas, versión, ventana, URL y contratos CSV. |
| `src/pricing_canasta/pipeline.py` | CLI y orden de etapas. |
| `src/pricing_canasta/download.py` | Descarga, reintentos, hashes y manifiesto. |
| `src/pricing_canasta/ingest.py` | Saneamiento, tipado e ingestión transaccional. |
| `src/pricing_canasta/build.py` | Selección de inputs, ejecución SQL y publicación atómica. |
| `src/pricing_canasta/validate.py` | Linaje, gates, métricas y nivel de confianza. |
| `src/pricing_canasta/export.py` | CSV, Parquet, Excel, HTML y resumen. |
| `sql/01_schema.sql` | Tablas base y macros de normalización. |
| `sql/02_marts.sql` | Dimensiones, hechos y marts. |
| `sql/03_quality_checks.sql` | Gates altos y advertencias medias. |

## 5. Rutas y almacenamiento

### 5.1 Raíz del proyecto

```text
<directorio-del-clon>/pricing-canasta-supermercado
```

### 5.2 Almacenamiento pesado

La carpeta `data/` está ignorada por Git. Puede residir dentro del clon o ser un enlace
del sistema de archivos hacia un volumen con espacio suficiente, por ejemplo:

```text
<almacenamiento-externo>/pricing-canasta-supermercado/data
```

Antes de ejecutar una descarga o build, comprobar la ubicación y el espacio disponible.
Si se usa un junction o enlace simbólico, validar que el destino siga accesible.

```powershell
Get-Item -LiteralPath '.\data' | Format-List FullName,Attributes,LinkType,Target
Get-PSDrive -PSProvider FileSystem | Format-Table Name,Used,Free,Root -AutoSize
```

### 5.3 Layout

```text
data/
  raw/
    _landing/                 # descargas .part aún no publicadas
    YYYY-MM-DD/
      sepa_<slot>.zip         # raw oficial e inmutable
  interim/
    YYYY-MM-DD/<run_uuid>/    # ZIP interiores y CSV saneados temporales
    duckdb_temp/              # spill de DuckDB
  manifests/
    downloads.jsonl           # manifiesto operativo
  warehouse/
    pricing_v2_strict.duckdb  # base activa
    pricing_v2.duckdb         # candidato fallido/legacy
    pricing.duckdb            # warehouse v1 legado
  exports/                    # CSV y Parquet generados

docs/                         # documentación
manifests/                    # manifiesto público versionable
outputs/                      # entregables locales regenerables e ignorados
portfolio_data/               # CSV pequeños para portfolio y Power BI
powerbi/                      # tema, medidas DAX e instrucciones
reports/                      # snapshots Markdown versionados
site/                         # dashboard liviano para GitHub Pages
sql/                          # esquema, marts y controles
src/pricing_canasta/          # paquete Python instalable
tests/                        # pruebas automatizadas
```

### 5.4 Política de retención recomendada

| Elemento | Retención |
|---|---|
| ZIP raw oficiales | Permanente e inmutable. |
| Manifiestos y hashes | Permanente. |
| Warehouse publicado | Conservar y respaldar antes de reemplazos mayores. |
| Warehouse legado | Conservar hasta aprobar v2; luego archivar fuera de la ruta activa. |
| Workdirs de runs vivos | No eliminar. |
| Workdirs huérfanos | Eliminar sólo sin procesos Python/DuckDB activos. |
| `duckdb_temp` huérfano | Eliminar sólo con DuckDB cerrado. |
| Exports | Regenerables desde el warehouse publicado. |

## 6. Entorno y dependencias

### 6.1 Python

Versión requerida:

```text
Python 3.11.4
```

Está fijada en `.python-version` y `pyproject.toml`.

### 6.2 Dependencias directas

| Paquete | Versión | Uso |
|---|---:|---|
| `duckdb` | 1.5.5 | Warehouse, SQL, CSV y Parquet. |
| `pandas` | 2.3.3 | DataFrames y exportaciones pequeñas. |
| `pyarrow` | 24.0.0 | Parquet desde pandas. |
| `openpyxl` | 3.1.5 | Excel. |
| `plotly` | 6.9.0 | Dashboards HTML. |
| `requests` | 2.34.2 | API y descarga HTTP. |
| `urllib3` | 2.7.0 | Política de reintentos HTTP. |
| `pytest` | 9.1.1 | Pruebas. |
| `pytest-cov` | 7.0.0 | Integración de coverage. |
| `coverage` | 7.10.7 | Medición de cobertura. |
| `ruff` | 0.12.12 | Lint e imports. |

Las dependencias directas están declaradas en `pyproject.toml`; `uv.lock` fija también
las transitivas para instalaciones reproducibles.

### 6.3 Instalación

```powershell
uv sync --extra dev --locked
uv run ruff check src tests
uv run pytest -q
```

Como alternativa, crear `.venv` e instalar con `pip install -e ".[dev]"`.

### 6.4 Configuración DuckDB

`src/pricing_canasta/ingest.py::connect()` configura:

- cuatro hilos;
- `preserve_insertion_order=false`;
- almacenamiento temporal en `data/interim/duckdb_temp`;
- tablas y macros de `sql/01_schema.sql`.

`DUCKDB_THREADS` permite ajustar hilos sin cambiar código. Para modificar rutas, ventana,
URL o versión se actualiza `src/pricing_canasta/config.py` y se prueban todos los stages.

## 7. Contrato de fuente

### 7.1 Recurso exterior

Cada fecha debe tener exactamente un archivo:

```text
data/raw/YYYY-MM-DD/sepa_*.zip
```

El ZIP exterior contiene ZIP interiores por comercio. La raíz interna debe coincidir
con la fecha de la carpeta exterior.

### 7.2 Archivos interiores obligatorios

| Archivo | Columnas | Contenido |
|---|---:|---|
| `comercio.csv` | 8 | Comercio, bandera y metadatos. |
| `sucursales.csv` | 21 | Sucursal, geografía y horarios. |
| `productos.csv` | 17 | Producto, presentación y precios. |

El orden y nombre de columnas está definido en
`src/pricing_canasta/config.py::EXPECTED_COLUMNS`.
El encabezado debe coincidir exactamente. No se acepta agregar, quitar, renombrar o
reordenar columnas sin modificar el contrato y sus pruebas.

### 7.3 Reglas estructurales

- Separador: `|`.
- Encoding: UTF-8.
- BOM UTF-8 permitido sólo en encabezado.
- Autodetección desactivada.
- `strict_mode=true`.
- `null_padding=false`.
- `ignore_errors=false`.
- Paquete interior vacío permitido sólo para el patrón conocido `comercio-sepa-36_`.

### 7.4 Saneamiento permitido

`sanitize_csv()` únicamente:

1. reemplaza el encabezado por el encabezado canónico;
2. elimina bytes NUL y contabiliza cuántos;
3. omite líneas completamente vacías;
4. elimina el footer técnico de última actualización si está al final;
5. reconstruye continuaciones físicas que empiezan con `|` cuando la fila previa tiene
   menos campos que el contrato;
6. contabiliza filas, footers, NUL y líneas reconstruidas.

No se permite rellenar silenciosamente columnas faltantes. El defecto de Comodín se
reconstruye porque la fuente divide latitud, longitud y resto del registro en líneas
físicas consecutivas; el resultado final sigue siendo validado contra 21 campos.

### 7.5 Tipado tolerante de valores

La estructura es estricta, pero valores individuales se convierten con `TRY_CAST`:

- fechas inválidas pasan a `NULL`;
- coordenadas inválidas pasan a `NULL`;
- cantidades y precios no numéricos pasan a `NULL`;
- precios nulos, cero o negativos se conservan con `precio_lista_valido=false`.

Esta decisión evita perder la fila fuente y permite cuantificar el problema en quality gates.

## 8. CLI y orden de ejecución

### 8.1 Sintaxis

```powershell
uv run pricing-canasta <stage> [opciones]
```

Stages:

| Stage | Acción |
|---|---|
| `download` | Consulta catálogo y descarga siete ZIP. |
| `ingest` | Ingiere snapshots raw. |
| `build` | Construye y publica marts. |
| `validate` | Verifica build publicado y genera informe. |
| `export` | Valida y genera todos los entregables. |
| `all` | Ejecuta download, ingest, build y export. |

Opciones:

| Opción | Efecto |
|---|---|
| `--as-of YYYY-MM-DD` | Filtra ingestión y fija el fin de la ventana del build. |
| `--only-snapshot YYYY-MM-DD` | Limita ingestión a una fecha. |
| `--force` | Reemplaza una fecha ya activa durante ingestión. |

`--force` y `--only-snapshot` no afectan al build. La CLI no rechaza opciones que un
stage no usa, por lo que deben aplicarse conscientemente.

### 8.2 Ejecución reproducible recomendada

```powershell
uv run pricing-canasta download
uv run pricing-canasta ingest --as-of 2026-08-02
uv run pricing-canasta build --as-of 2026-08-02
uv run pricing-canasta validate
uv run pricing-canasta export
```

Usar una fecha explícita en publicaciones. Sin `--as-of`, el build usa la fecha máxima
disponible y la ejecución futura puede producir otro corte.

### 8.3 Ejecución aislada de una fecha

```powershell
uv run pricing-canasta ingest `
  --only-snapshot 2026-08-02 `
  --as-of 2026-08-02
```

Reemplazo intencional:

```powershell
uv run pricing-canasta ingest `
  --only-snapshot 2026-08-02 `
  --as-of 2026-08-02 `
  --force
```

## 9. Stage `download`

### 9.1 Flujo

1. Lee `data/manifests/downloads.jsonl`.
2. Consulta el catálogo oficial CKAN.
3. Exige exactamente siete recursos ZIP.
4. Normaliza cada recurso a un slot.
5. Ejecuta `HEAD` para ETag y tamaño.
6. Reutiliza el archivo si metadatos y SHA-256 coinciden.
7. Descarga en bloques de 8 MiB hacia `raw/_landing/*.part`.
8. Verifica `Content-Length`, estructura ZIP, fecha interna, CRC y SHA-256.
9. Publica el ZIP con `os.replace`.
10. Reemplaza el manifiesto mediante archivo temporal y `fsync`.

### 9.2 Reintentos

- Cinco reintentos.
- Backoff factor 1.
- Estados: 408, 429, 500, 502, 503 y 504.
- Métodos: GET y HEAD.
- Timeout catálogo/HEAD: connect 10 s, read 60 s.
- Timeout descarga: connect 10 s, read 300 s.

### 9.3 Idempotencia

- Mismo recurso, tamaño y hash: no redescarga.
- Descarga con mismo hash que destino: deduplica.
- Destino existente con hash diferente: aborta para proteger inmutabilidad raw.

### 9.4 Atomicidad real

Cada ZIP se publica individualmente. El lote completo de siete ZIP no es transaccional.
Si falla el quinto recurso, los cuatro anteriores pueden haber sido movidos aunque el
manifiesto nuevo aún no se haya publicado. Repetir `download` es la recuperación normal.

### 9.5 Diagnóstico

```powershell
Get-ChildItem -LiteralPath '.\data\raw\_landing' -Force
Get-Content -LiteralPath '.\data\manifests\downloads.jsonl'
```

Verificar un ZIP:

```powershell
uv run python -c "from pathlib import Path; from pricing_canasta.download import _validate_zip; p=Path(r'data/raw/2026-08-02/sepa_domingo.zip'); print(_validate_zip(p))"
```

## 10. Stage `ingest`

### 10.1 Descubrimiento

Busca `data/raw/20??-??-??/sepa_*.zip`. No usa el manifiesto para descubrir inputs.
Exige un único ZIP por fecha.

### 10.2 Transacción por snapshot

1. Calcula SHA-256 del ZIP exterior.
2. Marca un run previo `running` de esa fecha como `interrupted`.
3. Si fecha y hash ya están activos, termina sin duplicar.
4. Si la fecha tiene otro hash y no hay `--force`, aborta.
5. Inserta `pipeline_runs(status='running')`.
6. Inicia transacción.
7. Elimina filas anteriores de esa fecha en tablas fuente.
8. Sanea y carga todos los paquetes interiores.
9. Reconcilia filas fuente y filas cargadas.
10. Exige al menos un paquete no vacío y una fila de precio.
11. Actualiza `snapshot_state`.
12. Marca el run como `success` y hace commit.

Ante una excepción, DuckDB hace rollback y el snapshot activo anterior permanece.

### 10.3 Tablas escritas

| Tabla | Uso |
|---|---|
| `pipeline_runs` | Estado general del run. |
| `ingestion_log` | Métricas por paquete/archivo. |
| `commerce_snapshot` | Filas de `comercio.csv`. |
| `store_snapshot` | Filas de `sucursales.csv`. |
| `fact_price` | Filas de `productos.csv`. |
| `snapshot_state` | Puntero a la versión activa de la fecha. |

### 10.4 Limitación de auditoría

`ingestion_log` se escribe dentro de la transacción. Si el snapshot falla, las filas de
detalle del intento se revierten; el error general queda en `pipeline_runs.details`.
Conservar la salida de consola cuando se investiga un archivo estructuralmente inválido.

### 10.5 Recuperación

Un cierre normal elimina su workdir en `finally`. Un kill duro no ejecuta ese bloque y
puede dejar CSV/ZIP temporales. Repetir la fecha marca el run huérfano como interrumpido,
pero no elimina workdirs de UUID anteriores.

## 11. Clasificación de productos

### 11.1 `normalize_gtin14`

Acepta sólo códigos marcados como EAN con longitud 8, 12, 13 o 14. Completa con ceros
a la izquierda hasta 14 dígitos.

### 11.2 `is_valid_gtin14`

Comprueba que haya 14 dígitos y valida el dígito de control con ponderación alternada 3/1.

### 11.3 `classify_product_code`

Orden de clasificación:

1. patrón restringido `20-29` -> `RESTRICTED_LOCAL`;
2. indicador EAN falso -> `INTERNAL_LOCAL`;
3. GTIN válido -> `GLOBAL_GTIN`;
4. cualquier otro caso -> `INVALID`.

La clasificación restringida tiene prioridad. Un código de peso/uso interno no entra en
comparaciones globales aunque la fuente lo marque como EAN.

### 11.4 Unidades

`normalize_unit` unifica gramos, kilogramos, mililitros, litros y unidades a:

```text
G, KG, ML, L, UN
```

Unidades desconocidas se conservan en mayúsculas para no inventar equivalencias.

## 12. Stage `build`

### 12.1 Selección de inputs

El build toma una fecha `as_of` y calcula:

```text
window_start = as_of - 6 días
```

Consulta `snapshot_state` y exige exactamente las siete fechas consecutivas. Guarda
`snapshot_date`, `active_ingest_run_id` y `raw_sha256` en `build_inputs`.

El `source_set_hash` es SHA-256 de las siete líneas ordenadas:

```text
snapshot_date|active_ingest_run_id|raw_sha256
```

### 12.2 Verificación del grano global

Antes de proyectar el hecho comparable, el build busca duplicados en:

```text
fecha + comercio + bandera + sucursal + gtin14
```

Filtros: `GLOBAL_GTIN`, precio válido y claves completas. Si encuentra una duplicación,
aborta. Esta verificación permite que `fct_global_price_store_daily` sea una proyección
eficiente en lugar de una agregación de casi 95 millones de filas.

### 12.3 Publicación transaccional

1. Marca builds `running` previos como `interrupted`.
2. Inserta un run `running`.
3. Inicia una transacción.
4. Crea `build_context` temporal.
5. Inserta `build_inputs`.
6. Verifica grano global.
7. Ejecuta las 35 sentencias de `sql/02_marts.sql` en orden.
8. Crea `quality_checks` con `sql/03_quality_checks.sql`.
9. Aborta si existe una falla alta.
10. Verifica tablas requeridas y `build_id`.
11. Reemplaza `warehouse_state`.
12. Marca éxito, commit y checkpoint.

Si cualquier paso falla, todos los marts nuevos se revierten y el build anterior continúa
visible. No hacer commits parciales entre marts.

### 12.4 Contrato de formato SQL

`build.py` divide `02_marts.sql` con `script.split(";\n")`. Cada sentencia debe terminar
con punto y coma seguido de salto de línea. No colocar `;` finales en una forma que rompa
esta segmentación sin cambiar `_split_sql()` y sus pruebas.

## 13. Catálogo completo de tablas

El warehouse contiene ocho tablas base/control, 35 tablas analíticas y `quality_checks`.
`build_context` e `import_batch` son temporales.

### 13.1 Control y linaje

#### `pipeline_runs`

- Grano: una ejecución por `run_id`.
- Etapas registradas: `ingest` y `build`.
- Estados: `running`, `success`, `failed`, `interrupted`.
- Columnas clave: fechas, build, hashes, timestamps, contadores y detalle.
- `parent_run_id` existe pero actualmente no se usa.
- Consumidor: operación y troubleshooting, no marts analíticos.

#### `snapshot_state`

- Grano: una fila por fecha.
- PK: `snapshot_date`.
- Contiene el `active_ingest_run_id` y hash raw activos.
- Es la fuente autoritativa para seleccionar snapshots del build.

#### `ingestion_log`

- Grano: run × paquete × archivo, salvo paquetes vacíos conocidos.
- Contiene filas fuente/cargadas, footers, NUL, reconstrucciones y estado.
- Alimenta reconciliación y advertencias estructurales.
- No tiene PK; evitar inserciones manuales.

#### `build_inputs`

- Grano: build × fecha.
- PK compuesta.
- Fija run de ingestión y hash exactos usados por el build.
- Conserva linaje de builds anteriores.

#### `warehouse_state`

- Grano: singleton.
- Define el único build publicado.
- Contiene corte, ventana, `source_set_hash`, versión y fecha de publicación.
- Nunca actualizar manualmente para “forzar” una publicación.

### 13.2 Tablas fuente

#### `commerce_snapshot`

- Grano físico: fila de `comercio.csv` por run/fecha/paquete.
- Columnas: comercio, bandera, CUIT, razón social, nombre, URL, timestamp y versión SEPA.
- Consumidor: `dim_banner_daily`.

#### `store_snapshot`

- Grano físico: fila de sucursal por run/fecha/paquete.
- Columnas: claves, nombre, tipo, dirección, geografía, horarios y coordenadas.
- `coordenadas_validas` exige rangos geográficos válidos.
- Provincia se recorta, pero no se contrasta contra un maestro.
- Consumidor: `dim_store_daily`.

#### `fact_price`

- Grano físico esperado: fecha × comercio × bandera × sucursal × producto declarado.
- Conserva observaciones válidas e inválidas.
- Columnas centrales: `gtin14`, alcance, descripción, marca, presentación, lista,
  referencia, promociones y flags de validez.
- Consumidores: dimensiones de producto, hechos global/local y calidad diaria.

### 13.3 Dimensiones

#### `dim_banner_daily`

- Grano: build × fecha × comercio × bandera.
- Entrada: `commerce_snapshot` del run seleccionado.
- Deduplica por actualización más reciente, paquete y nombre.
- Consumidores: etiquetas en canasta y dispersión.

#### `dim_store_daily`

- Grano: build × fecha × comercio × bandera × sucursal.
- Entrada: `store_snapshot`.
- Exige claves completas y deduplica determinísticamente.
- Consumidores: provincia en precios, dispersión, canasta y export Parquet.

#### `dim_product_variant_asof`

- Grano: build × GTIN × variante descriptiva/presentación.
- Entrada: observaciones `GLOBAL_GTIN` de siete días.
- Métricas: observaciones, última fecha y último paquete.
- Convierte KG/G a base G, L/ML a base ML y conserva UN.
- Consumidores: dimensión canónica y auditoría de canasta.

#### `dim_product_asof`

- Grano: build × GTIN.
- Elige la variante modal; desempata por fecha, paquete y atributos.
- Consumidores: drivers, anomalías, dispersión y exports.

#### `dim_banner_scope`

- Grano: build × versión de alcance × comercio × bandera.
- Define siete cadenas fijas en `IDX_GROCERY_7_V1`.
- No se seleccionan automáticamente por cobertura.
- Consumidores: salud cadena-día, índice y etiquetas.

#### `dim_basket_version`

- Grano: build × versión de canasta.
- Versión actual: `CANASTA_2026W31_V1`.
- Declara precio de lista, ocho GTIN, sin promociones ni imputación.

#### `dim_basket_component`

- Grano: build × versión × categoría.
- Contiene ocho GTIN, presentación objetivo, regex y justificación.
- La unicidad de categoría y GTIN es gate alto.

### 13.4 Hechos comparables y locales

#### `fct_global_price_store_daily`

- Grano: build × fecha × comercio × bandera × sucursal × GTIN.
- Sólo `GLOBAL_GTIN`, precio válido y claves completas.
- `list_price` es precio de lista; no usa promociones.
- Depende de la verificación previa de unicidad.
- Consumidores: precio producto, salud, índice, canasta y dispersión.

#### `fct_local_price_store_daily`

- Grano: build × fecha × comercio × bandera × sucursal × producto × alcance local.
- Sólo `RESTRICTED_LOCAL` e `INTERNAL_LOCAL`.
- Usa medianas por grupo y calcula referencia por kg, litro o unidad.
- No se exporta actualmente; queda disponible para análisis local y auditoría.

#### `bridge_analysis_product_daily`

- Grano: build × fecha × GTIN.
- Unión del panel común del índice y los ocho GTIN de canasta.
- Limita anomalías y dispersión al universo analítico relevante.

#### `fct_analysis_price_store_daily`

- Grano: build × fecha × comercio × bandera × sucursal × GTIN analítico.
- Añade provincia al hecho global filtrado.
- Consumidores: anomalías, dispersión y canasta.

### 13.5 Calidad y salud

#### `mart_quality_daily`

- Grano: build × fecha.
- Cuenta filas, tiendas, GTIN, alcances, precios inválidos, claves nulas y promociones.
- Consumidores: salud nacional, validación y export.

#### `mart_snapshot_health`

- Grano: build × fecha.
- Compara filas y tiendas con sus medianas semanales.
- Saludable si ambos ratios son al menos 80%.
- Consumidores: gate medio, dashboard e informe.

#### `mart_banner_day_health`

- Grano: build × alcance × fecha × cadena.
- Construye grilla completa 7 días × 7 cadenas.
- Ausencias se representan como cero.
- Saludable si filas y tiendas alcanzan 80% de la mediana de esa cadena.
- Una cadena no saludable elimina todo el día del índice común.

#### `quality_price_anomaly_daily`

- Grano lógico: evento tienda-GTIN-fecha-tipo.
- Tipos: `SCALE_FACTOR`, `CROSS_SECTION_OUTLIER`, `TEMPORAL_JUMP`.
- Puede haber más de un evento para la misma observación.
- Consumidores: dispersión limpia, quality gate medio y export.

### 13.6 Índice y persistencia

#### `mart_banner_product_daily`

- Grano: build × alcance × fecha × cadena × GTIN.
- Sólo cadenas y días saludables.
- `banner_price` es mediana de sucursales.
- Consumidores: persistencia, panel común y overlap.

#### `mart_product_persistence_7d`

- Grano: build × fin de ventana × cadena × GTIN.
- Persistencia condicional: días observados / días saludables.
- Persistencia calendario: días observados / 7.
- `strict_persistent_7d` exige siete días saludables y siete apariciones.

#### `bridge_index_common_gtin_daily`

- Grano: build × alcance × fecha × GTIN.
- Requiere las siete cadenas saludables.
- Requiere el GTIN presente en las siete cadenas.

#### `mart_banner_index_relative_daily`

- Grano: build × alcance × fecha × cadena × GTIN común.
- Calcula benchmark geométrico y precio relativo.
- Entrada de índice, drivers y sensibilidad.

#### `mart_banner_index_daily`

- Grano: build × alcance × fecha × cadena.
- Índice geométrico de relativos multiplicado por 100.
- Publicable con al menos 500 GTIN comunes.
- El centro geométrico entre cadenas debe ser 100.

#### `mart_banner_index_7d`

- Grano: build × alcance × cadena.
- Media geométrica semanal, mínimo, máximo, desviación y cobertura.
- `publishable_all_observed_days` no exige necesariamente siete días existentes.

#### `mart_banner_index_driver_daily`

- Grano: relativo cadena-GTIN-día.
- Contribución: `100/N * ln(price_relative)`.
- Ranking por magnitud absoluta del logaritmo.
- Export limita a 15 drivers por cadena-día.

#### `mart_banner_index_sensitivity_daily`

- Grano: build × alcance × fecha × cadena.
- Compara índice raw, sin relativos fuera de 0,5-2 y winsorizado a ese rango.
- Permite medir sensibilidad a extremos.

#### `mart_banner_pair_overlap_daily`

- Grano: build × alcance × fecha × par no ordenado de cadenas.
- Métricas: GTIN comunes, containment y Jaccard.
- Publicable con al menos 500 GTIN y 20% de containment.

### 13.7 Dispersión

#### `mart_price_product_daily`

- Grano: build × fecha × GTIN × comercio × bandera × provincia.
- Métricas: tiendas, mínimo, máximo, P10, mediana y P90.
- Provincia faltante se representa como `SIN_DATO`.
- Export grande: `price_product_daily.parquet`.

#### `mart_price_dispersion_daily`

- Grano: build × fecha × GTIN × nivel × entidad.
- Niveles: nacional, cadena, provincia y cadena-provincia.
- Calcula raw y clean; clean excluye anomalías críticas.
- Dispersión: `(P90 - P10) / mediana`.
- Estados: `PUBLISHABLE`, `DIRECTIONAL`, `SUPPRESSED`.

#### `mart_dispersion_entity_daily`

- Grano: build × fecha × nivel × entidad.
- Resume productos publicables y mediana de dispersión.
- Entidad publicable con al menos 100 productos publicables.
- Direccional con al menos 30 productos no suprimidos.

### 13.8 Canasta

#### `mart_basket_candidate_review`

- Grano: build × versión × categoría × GTIN candidato.
- Evalúa regex semántica y presentación dentro de ±2%.
- Conserva una variante por candidato.
- Gate alto exige que los ocho seleccionados cumplan semántica y presentación.

#### `mart_basket_component_store_daily`

- Grano: build × versión × fecha × tienda × categoría.
- Unión exacta entre GTIN observado y componente fijo.
- `component_cost=list_price`; no escala ni imputa.

#### `mart_basket_store_daily`

- Grano: build × versión × fecha × tienda.
- Suma componentes observados.
- `complete_basket=true` sólo con ocho componentes.
- Los agregados de costo usan únicamente canastas completas.

#### `mart_basket_banner_daily`

- Grano: build × versión × fecha × cadena.
- Métricas: tiendas activas/completas, completitud, media, mediana, P10 y P90.
- Publicable con 20 tiendas completas; direccional con 5.

#### `mart_basket_province_daily`

- Grano: build × versión × fecha × provincia.
- Publicable con 20 tiendas completas y tres cadenas.
- Direccional con cinco tiendas y dos cadenas.
- Geografía no `AR-*` se considera inválida.

#### `mart_basket_banner_province_daily`

- Grano: build × versión × fecha × cadena × provincia.
- Mediana en canastas completas.
- Publicable con 20 tiendas; direccional con cinco.

#### `mart_basket_national_daily`

- Grano: build × versión × fecha.
- Sólo provincias `AR-*` y canastas completas.
- Representa la red observada, no población.

#### `mart_basket_savings_daily`

- Grano: build × versión × fecha × nivel (`BANNER` o `PROVINCE`).
- Sólo grupos publicables.
- Ahorro absoluto: máximo menos mínimo.
- Ahorro porcentual: diferencia / máximo × 100.

### 13.9 Quality gates

#### `quality_checks`

- Grano esperado: build × nombre de test.
- Columnas: fallas, severidad y explicación.
- Creada después de los 35 marts.
- Un valor alto mayor que cero revierte el build completo.

## 14. Metodología analítica

### 14.1 Índice de nivel de precios

Para cada GTIN común `g`, cadena `b` y día `t`:

```text
benchmark(g,t) = exp(promedio_b(ln(precio(b,g,t))))
relativo(b,g,t) = precio(b,g,t) / benchmark(g,t)
indice(b,t) = 100 * exp(promedio_g(ln(relativo(b,g,t))))
```

Consecuencias:

- igual peso por cadena en el benchmark;
- igual peso por GTIN en el índice;
- no pondera ventas, hogares ni participación de mercado;
- todas las cadenas usan exactamente el mismo conjunto de GTIN;
- la media geométrica de índices del día debe ser 100.

### 14.2 Canasta

La canasta actual contiene:

| Categoría | GTIN | Presentación |
|---|---|---|
| Aceite | `07790272001029` | 1,5 L |
| Arroz | `07791120031557` | 1 kg |
| Azúcar | `07792540250450` | 1 kg |
| Café | `07790550022234` | 250 g |
| Fideos | `07790070320285` | 500 g |
| Harina | `07790070562258` | 1 kg |
| Leche | `07790742363008` | 1 L |
| Yerba | `07792710000182` | 500 g |

No se usan promociones. No se reemplaza un GTIN faltante por otro. No se escala una
presentación diferente. Una tienda incompleta conserva costo parcial para cobertura,
pero no entra en estadísticas de costo completo.

### 14.3 Anomalías

Benchmark transversal: mediana tienda nacional por GTIN-día.

- Advertencia transversal: ratio fuera de 0,667-1,5.
- Crítica transversal: ratio fuera de 0,5-2.
- Salto temporal: misma tienda-GTIN, días consecutivos, mismos umbrales.
- `SCALE_FACTOR`: ratio cercano a potencia entera de 10, tolerancia 5%.

### 14.4 Dispersión

```text
dispersion = (P90 - P10) / mediana
```

La versión clean excluye observaciones con anomalía crítica. Los estados de cobertura
evitan rankings con pocas tiendas o cadenas.

### 14.5 Nacional

Los resultados nacionales representan sucursales observadas. No hay ponderación por
población, facturación, gasto de hogares ni tamaño de cadena.

## 15. Quality gates y confianza

### 15.1 Gates altos

| Test | Regla |
|---|---|
| `build_input_count` | Exactamente siete inputs. |
| `build_input_boundaries` | Fechas iguales a ventana declarada. |
| `source_loaded_row_difference` | Cero diferencia fuente/carga. |
| `ingestion_structural_status` | Sólo `success` o vacío conocido. |
| `comparable_key_null` | Sin claves nulas en hecho global. |
| `restricted_code_in_global_fact` | Ningún código local en hecho global. |
| `daily_mart_date_count` | Siete fechas en mart diario. |
| `basket_component_count` | Ocho componentes. |
| `basket_component_uniqueness` | Categorías y GTIN únicos. |
| `basket_selected_semantic_or_presentation_mismatch` | Seleccionados válidos. |
| `hileret_light_selected` | Hileret Light no puede ser azúcar blanca. |
| `index_common_panel_consistency` | Mismo panel en todas las cadenas. |
| `index_geometric_center` | Centro geométrico diario igual a 100. |

### 15.2 Advertencias medias

- paquetes vacíos conocidos;
- líneas reconstruidas;
- días nacionales o cadena-día no saludables;
- códigos EAN inválidos;
- precios inválidos;
- claves fuente nulas;
- anomalías críticas;
- geografía inválida;
- corte con más de 14 días.

### 15.3 Nivel de confianza

- Baja: falla alta/linaje, inputs incorrectos, antigüedad mayor a 30 días o salud menor a 80%.
- Media: advertencias, día no saludable o antigüedad mayor a 14 días.
- Alta: ningún criterio anterior.

La confianza mide calidad del corte publicado, no profundidad histórica. Una ventana limpia
de siete días puede alcanzar confianza Alta; aun así, siete días siguen siendo insuficientes
para afirmar tendencias, inflación, estacionalidad o superioridad estructural.

## 16. Stage `validate`

`validate()` abre DuckDB en modo sólo lectura y:

1. comprueba que exista `warehouse_state`;
2. verifica versión `2.0.0`;
3. valida `build_id` de tablas requeridas;
4. lee quality gates;
5. calcula salud, volumen, canasta y frescura;
6. asigna confianza;
7. escribe `outputs/validation_report.md`;
8. lanza excepción si hay fallas altas.

La lista `REQUIRED_BUILD_TABLES` no incluye las 35 tablas. Algunas tablas auxiliares
se validan indirectamente, pero el chequeo genérico de linaje no es exhaustivo.

## 17. Stage `export`

### 17.1 Precondición

Ejecuta `validate(..., raise_on_failure=True)` antes de escribir datos.

### 17.2 Exportaciones pequeñas

Se escriben CSV en `data/exports` y `portfolio_data`, y Parquet en `data/exports`:

```text
quality_daily
quality_checks
source_health
banner_health
basket_definition
basket_candidate_review
index_daily
index_7d
index_sensitivity
index_drivers
banner_overlap
dispersion_entity
dispersion_product_sample
basket_banner
basket_province
basket_banner_province
basket_national
basket_savings
price_anomalies_sample
```

Los archivos con sufijo `_sample` tienen un máximo de 10.000 filas. Anomalías prioriza
severidad crítica antes que fecha; el dataset completo permanece en DuckDB. El export
elimina nombres legacy sin `build_id` para impedir mezclas entre metodologías.

### 17.3 Exportaciones grandes

```text
price_product_daily.parquet
basket_store_daily.parquet
basket_component_store_daily.parquet
product_dimension.parquet
store_dimension_daily.parquet
```

### 17.4 Entregables ejecutivos

| Archivo | Uso |
|---|---|
| `outputs/pricing_canasta_supermercado.xlsx` | Libro operativo. |
| `outputs/dashboard_pricing_canasta.html` | Dashboard desktop autosuficiente. |
| `outputs/dashboard_mobile.html` | Variante móvil. |
| `outputs/resumen_ejecutivo.md` | Hallazgos y limitaciones. |
| `outputs/validation_report.md` | Gates, linaje y confianza. |
| `outputs/run_metadata.json` | Build y nombres de entregables. |
| `powerbi/PricingCanasta.pbip` | Proyecto Power BI editable. |
| `powerbi/PricingCanasta.pbix` | Binario validado con datos importados. |

### 17.5 Atomicidad

Export no es transaccional. Sobrescribe archivos de nombre fijo. Si falla a mitad puede
quedar una mezcla de generaciones. La recuperación es corregir la causa y repetir `export`
completo. `run_metadata.json` se escribe al final y sirve para reconocer una generación
completa, aunque tampoco se publica con staging atómico.

## 18. Power BI

### 18.1 Arquitectura del proyecto

Power BI importa tablas agregadas de `portfolio_data`, no `fact_price`. Esto evita cargar
97,5 millones de filas en Desktop y mantiene el reporte desacoplado del warehouse pesado.

Artefactos versionables:

| Ruta | Propósito |
|---|---|
| `powerbi/PricingCanasta.pbip` | Entrada del proyecto. |
| `powerbi/PricingCanasta.Report/` | Reporte PBIR, cuatro páginas y 26 visuales. |
| `powerbi/PricingCanasta.SemanticModel/model.bim` | Modelo TMSL. |
| `powerbi/build_pbip.ps1` | Generador reproducible mediante TOM. |
| `powerbi/measures.dax` | Referencia legible de las 17 medidas. |
| `powerbi/PricingCanasta.pbix` | Entregable binario validado. |

El modelo contiene 14 tablas: 12 CSV, `Calendario` y `Medidas`; mantiene 9 relaciones
activas uno-a-muchos desde calendario. `DataFolder` es un parámetro M para reubicar
`portfolio_data` sin reescribir todas las particiones.

Fuentes importadas:

- `index_daily.csv`, `index_7d.csv`, `index_sensitivity.csv` e `index_drivers.csv`;
- `basket_banner.csv`, `basket_province.csv`, `basket_definition.csv` y `basket_savings.csv`;
- `dispersion_entity.csv`;
- `source_health.csv`, `banner_health.csv` y `quality_checks.csv`.

### 18.2 Páginas

1. `Panorama ejecutivo`: GTIN comunes, salud, ahorro, sensibilidad, índice y canasta.
2. `Canasta fija`: costos por cadena/provincia y definición de ocho componentes.
3. `Calidad y cobertura`: fallas, precios inválidos, dispersión, cobertura y gates.
4. `Drivers y sensibilidad`: contribuciones de productos y escenarios robustos.

![Panorama ejecutivo en Power BI](images/powerbi_panorama.png)

![Calidad y cobertura en Power BI](images/powerbi_calidad.png)

### 18.3 Semántica temporal de dispersión

El corte `2026-08-02` tiene filas de dispersión, pero todas están `SUPPRESSED`. Una medida
que calcula primero `MAX(snapshot_date)` y filtra después `PUBLISHABLE` devuelve blanco.
La implementación correcta obtiene la fecha dentro del universo publicable:

```dax
VAR Fecha =
    MAXX(
        FILTER(
            ALL(dispersion_entity),
            dispersion_entity[coverage_status] = "PUBLISHABLE"
        ),
        dispersion_entity[snapshot_date]
    )
```

`Dispersion limpia` y `Productos dispersion publicables` reutilizan esa fecha. Para el
build publicado es `2026-07-31`: `3,4%` de dispersión limpia mediana y `29.812` conteos
producto-entidad. La lógica no altera el estado del `02/08`, no imputa ceros y no permite
rankings de entidades suprimidas.

### 18.4 Construcción y validación

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\powerbi\build_pbip.ps1
```

Si `AllSigned` bloquea scripts sin firma:

```powershell
cmd.exe /d /c "type powerbi\build_pbip.ps1 | powershell.exe -NoProfile -Command -"
```

El generador serializa y deserializa `model.bim` con TOM antes de finalizar. Después se
abre `PricingCanasta.pbip`, se ejecuta **Actualizar** y se guarda el PBIX desde Desktop.
No existe conversión PBIP-PBIX headless oficial. Si Desktop ofrece migrar TMSL a TMDL,
elegir **No actualizar** para conservar el formato reproducible del generador.

Validación observada en Desktop `2.156.951.0`:

| Control | Resultado |
|---|---:|
| Tablas | 14 |
| Relaciones activas | 9 |
| Medidas | 17 |
| Filas de índice | 35 |
| Filas de canasta por cadena | 174 |
| Quality checks | 25 |
| GTIN comunes | 634 |
| Ahorro potencial | $5.163 |
| Salud cadena-día | 85,7% |
| Fallas altas | 0 |
| Último corte de dispersión publicable | 2026-07-31 |
| Dispersión limpia mediana | 3,4% |
| Conteos producto-entidad publicables | 29.812 |

La validación semanal de salud (`47/49`, `95,9%`) y la tarjeta del último corte
(`6/7`, `85,7%`) tienen ventanas diferentes y no deben reconciliarse como si fueran el
mismo indicador.

## 19. Pruebas

### 19.1 Comandos

```powershell
& $py -m pytest -q

& $py -m pytest `
  --cov=src `
  --cov-report=term-missing `
  --cov-fail-under=80
```

Estado verificado: 60 pruebas y cobertura total superior al 80%.

### 19.2 Cobertura funcional

| Archivo | Cobertura principal |
|---|---|
| `test_download.py` | Hash, ETag, retry, ZIP y manifiesto. |
| `test_csv_contract.py` | BOM, NUL, footer, reconstrucción y header. |
| `test_ingest.py` | Idempotencia, force, rollback y recuperación. |
| `test_build.py` | Ventana, matemáticas, duplicados y rollback. |
| `test_gtin.py` | Normalización, checksum y alcance. |
| `test_metric_math.py` | Índice y dispersión. |
| `test_export.py` | Excel, dashboards, Parquet y resumen. |
| `test_pipeline_cli.py` | Orden y propagación de opciones. |

## 20. Operación diaria

### 20.1 Preflight

```powershell
$py = '.\.venv\Scripts\python.exe'

Test-Path -LiteralPath $py
& $py --version
& $py -m pip check
Get-Item -LiteralPath '.\data' | Format-List FullName,LinkType,Target
Get-PSDrive -PSProvider FileSystem | Format-Table Name,Free -AutoSize
```

No ejecutar si:

- Python no es 3.11.4;
- `pip check` falla;
- `data` no existe, su enlace está roto o no tiene espacio suficiente;
- hay poco espacio libre;
- otro proceso escribe la misma base.

### 20.2 Publicación

```powershell
uv run pricing-canasta download
uv run pricing-canasta ingest --as-of <FECHA>
uv run pricing-canasta build --as-of <FECHA>
uv run pricing-canasta validate
uv run pricing-canasta export
```

### 20.3 Post-check

```powershell
uv run python -c "import duckdb; from pricing_canasta.config import DATABASE_PATH; c=duckdb.connect(str(DATABASE_PATH),read_only=True); print(c.execute('select * from warehouse_state').fetchall()); print(c.execute('select count(*) from pipeline_runs where status=?',['running']).fetchone()); print(c.execute('select coalesce(sum(failed_rows),0) from quality_checks where severity=?',['high']).fetchone())"
```

Revisar:

- `outputs/validation_report.md`;
- `outputs/resumen_ejecutivo.md`;
- `outputs/run_metadata.json`;
- tamaño y fecha de Excel/HTML;
- que no aparezcan `None`, `NaN` o rankings suprimidos.

## 21. SQL de diagnóstico

### 21.1 Estado publicado

```sql
SELECT * FROM warehouse_state WHERE singleton;
```

### 21.2 Inputs del build publicado

```sql
SELECT i.*
FROM build_inputs AS i
JOIN warehouse_state AS w
  ON i.build_id = w.published_build_id
ORDER BY i.snapshot_date;
```

Debe devolver siete fechas consecutivas.

### 21.3 Runs pendientes o fallidos

```sql
SELECT stage, snapshot_date, as_of_date, status,
       started_at, finished_at, details
FROM pipeline_runs
WHERE status <> 'success'
ORDER BY started_at DESC;
```

Un historial `failed/interrupted` no es pendiente. Una fila `running` sin proceso activo sí.

### 21.4 Reconciliación de ingestión

```sql
SELECT status,
       COUNT(*) AS logs,
       SUM(source_rows) AS source_rows,
       SUM(loaded_rows) AS loaded_rows,
       SUM(abs(coalesce(source_rows,0)-coalesce(loaded_rows,0))) AS difference,
       SUM(null_bytes_removed) AS null_bytes,
       SUM(reconstructed_lines) AS reconstructed
FROM ingestion_log
GROUP BY status
ORDER BY status;
```

### 21.5 Linaje activo contra publicado

```sql
SELECT i.snapshot_date, i.ingest_run_id AS build_run,
       s.active_ingest_run_id AS active_run,
       i.raw_sha256 AS build_hash, s.raw_sha256 AS active_hash
FROM build_inputs AS i
JOIN warehouse_state AS w ON i.build_id = w.published_build_id
JOIN snapshot_state AS s USING (snapshot_date)
WHERE i.ingest_run_id <> s.active_ingest_run_id
   OR i.raw_sha256 <> s.raw_sha256;
```

Debe devolver cero filas.

### 21.6 Duplicados globales

```sql
SELECT p.snapshot_date, p.id_comercio, p.id_bandera,
       p.id_sucursal, p.gtin14, COUNT(*) AS rows
FROM fact_price AS p
JOIN build_inputs AS i
  ON p.ingest_run_id = i.ingest_run_id
 AND p.snapshot_date = i.snapshot_date
JOIN warehouse_state AS w ON i.build_id = w.published_build_id
WHERE p.product_code_scope = 'GLOBAL_GTIN'
  AND p.precio_lista_valido
  AND p.id_comercio IS NOT NULL
  AND p.id_bandera IS NOT NULL
  AND p.id_sucursal IS NOT NULL
GROUP BY 1,2,3,4,5
HAVING COUNT(*) > 1;
```

### 21.7 Quality gates

```sql
SELECT severity, test_name, failed_rows, details
FROM quality_checks
ORDER BY severity, test_name;
```

### 21.8 Salud no válida

```sql
SELECT *
FROM mart_snapshot_health
WHERE NOT source_healthy
ORDER BY snapshot_date;

SELECT snapshot_date, banner_label, row_coverage_ratio,
       store_coverage_ratio, reporting_stores
FROM mart_banner_day_health
WHERE NOT source_healthy
ORDER BY snapshot_date, banner_label;
```

### 21.9 Ausencia de fecha en índice

```sql
SELECT snapshot_date,
       COUNT(*) AS scope_banners,
       COUNT(*) FILTER (WHERE source_healthy) AS healthy_banners
FROM mart_banner_day_health
GROUP BY snapshot_date
ORDER BY snapshot_date;

SELECT snapshot_date, COUNT(*) AS common_gtins
FROM bridge_index_common_gtin_daily
GROUP BY snapshot_date
ORDER BY snapshot_date;
```

### 21.10 Centro del índice

```sql
SELECT snapshot_date,
       MIN(common_gtins) AS min_panel,
       MAX(common_gtins) AS max_panel,
       100 * EXP(AVG(LN(price_index / 100))) AS geometric_center,
       BOOL_AND(publishable) AS all_publishable
FROM mart_banner_index_daily
GROUP BY snapshot_date
ORDER BY snapshot_date;
```

### 21.11 Validación de canasta

```sql
SELECT b.category_id, b.gtin14, r.producto_descripcion,
       r.semantic_match, r.presentation_match
FROM dim_basket_component AS b
LEFT JOIN mart_basket_candidate_review AS r
  ON b.build_id = r.build_id
 AND b.basket_version = r.basket_version
 AND b.category_id = r.category_id
 AND r.selected_component
WHERE r.gtin14 IS NULL
   OR NOT coalesce(r.semantic_match,false)
   OR NOT coalesce(r.presentation_match,false);
```

### 21.12 Motivo de canasta incompleta

```sql
SELECT snapshot_date, id_comercio, id_bandera,
       found_components, expected_components,
       COUNT(*) AS stores
FROM mart_basket_store_daily
WHERE NOT complete_basket
GROUP BY 1,2,3,4,5
ORDER BY found_components, snapshot_date;
```

### 21.13 Cobertura de dispersión

```sql
SELECT snapshot_date, dispersion_level, coverage_status,
       COUNT(*) AS products,
       MEDIAN(stores_clean) AS median_clean_stores,
       SUM(excluded_critical) AS excluded_prices
FROM mart_price_dispersion_daily
GROUP BY 1,2,3
ORDER BY snapshot_date, dispersion_level, coverage_status;
```

## 22. Matriz de fallas y recuperación

| Síntoma | Causa probable | Estado preservado | Acción |
|---|---|---|---|
| API no responde | Red, timeout, 429/5xx | Raw existente | Repetir download. |
| Queda `.part` | Descarga interrumpida | Destino final intacto | Verificar proceso y borrar temporal huérfano. |
| Raw existe con otro hash | Republicación o corrupción | Raw anterior | Investigar; no sobrescribir manualmente. |
| Más de un ZIP por fecha | Duplicado en raw | Warehouse intacto | Retirar archivo incorrecto y repetir ingest. |
| Header incompatible | Cambio de esquema | Snapshot anterior | Comparar contrato y fuente; no usar null padding. |
| Fila con columnas incorrectas | Fuente rota | Snapshot anterior | Inspeccionar bytes; documentar reparación específica. |
| Ingest falla | ZIP/CSV/tipo estructural | Snapshot anterior | Corregir y repetir sólo fecha. |
| Force-ingest falla | Nueva fuente defectuosa | Snapshot anterior | Corregir antes de repetir `--force`. |
| Run ingest queda `running` | Kill duro | Transacción revertida | Repetir misma fecha; quedará `interrupted`. |
| Workdir persiste | Kill duro | Datos publicados intactos | Eliminar sólo sin proceso activo. |
| Build dice ventana incompleta | Falta fecha activa | Build anterior | Ingerir fecha faltante. |
| Grano global duplicado | Duplicación fuente | Build anterior | Identificar clave y corregir upstream. |
| Quality gate alto | Regla metodológica incumplida | Build anterior | Revisar error, SQL y consola; no relajar sin decisión. |
| Build queda `running` | Kill duro | Build anterior | Repetir build; run previo será interrumpido. |
| DuckDB sin espacio | Spill o warehouse grande | Puede revertir | Liberar el volumen de `data/`, cerrar procesos y repetir. |
| Base bloqueada | Otro escritor abierto | Sin cambio | Cerrar Python/Power BI/proceso DuckDB. |
| Validate falla por versión | Código/base incompatibles | Base intacta | Usar revisión correcta o migrar esquema. |
| Export falla a mitad | Disco, archivo abierto, datos vacíos | Base intacta; archivos mezclados | Cerrar Excel, corregir y repetir export. |
| Dashboard muestra vacío | No hay cobertura publicable | Datos intactos | Revisar estados; no forzar ranking. |
| `data/` no está disponible | Enlace o montaje roto | Riesgo operativo | Restaurar el almacenamiento antes de ejecutar. |
| Base corrupta | Disco/kill excepcional | Sin restore automático | Restaurar backup o reconstruir desde raw. |

## 23. Limpieza segura de temporales

Antes de limpiar:

```powershell
Get-Process -Name python,pythonw -ErrorAction SilentlyContinue
```

No eliminar temporales si existe un proceso del proyecto. Los residuos típicos son:

- `data/raw/_landing/*.part`;
- `data/interim/YYYY-MM-DD/<uuid>/`;
- `data/interim/duckdb_temp/*.tmp`.

El proyecto no ofrece actualmente un comando oficial de cleanup. Documentar fecha,
tamaño y motivo antes de una eliminación manual. Nunca eliminar `raw`, manifiestos,
`snapshot_state`, `build_inputs` o el warehouse publicado como “limpieza”.

## 24. Backup y reconstrucción

### 24.1 Backup mínimo

Respaldar:

1. `data/raw`;
2. `data/manifests` y `manifests/raw_sources.jsonl`;
3. `pricing_v2_strict.duckdb`;
4. código Git y documentación;
5. opcionalmente outputs publicados.

### 24.2 Reconstrucción completa

Si el warehouse se pierde pero los raws están intactos:

1. mover la base corrupta fuera de `data/warehouse`;
2. confirmar rutas y espacio;
3. ejecutar ingestión de las siete fechas;
4. ejecutar build con `--as-of` explícito;
5. validar;
6. exportar;
7. comparar hashes, conteos y KPI con el último informe.

No eliminar la base anterior hasta verificar la nueva.

## 25. Cambios controlados

### 25.1 Cambio del esquema CSV

Modificar conjuntamente:

1. `EXPECTED_COLUMNS`;
2. SQL de carga en `src/pricing_canasta/ingest.py`;
3. tablas de `sql/01_schema.sql` si cambia el modelo persistente;
4. `SCHEMA_VERSION`;
5. fixtures y pruebas de contrato;
6. documentación;
7. estrategia de migración o nueva base candidata.

Nunca activar `ignore_errors` o `null_padding` para “hacer pasar” una evolución.

### 25.2 Cambio de cadenas del índice

Modificar `dim_banner_scope` en `02_marts.sql`, versión de alcance, documentación y
tests matemáticos. Reevaluar 500 GTIN comunes y salud de todas las cadenas.

### 25.3 Cambio de canasta

Crear una nueva `basket_version`; no mutar silenciosamente una versión publicada.
Definir GTIN, presentación, regex, justificación y vigencia. Verificar candidato,
semántica, presentación, cobertura y efecto sobre series.

### 25.4 Cambio de gates

Todo umbral afecta publicabilidad. Documentar motivación, evidencia, impacto histórico
y versión. Ejecutar sensibilidad antes de reducir requisitos.

### 25.5 Cambio de ventana

Actualizar `WINDOW_DAYS`, selección del build, divisores fijos `/7`, nombres `7d`,
persistencia, confianza, tests, documentación y costos de almacenamiento.

### 25.6 Cambio de base activa

Usar un nombre candidato nuevo, construir, validar y exportar antes de apuntar
`DATABASE_PATH`. No reutilizar una base fallida si su esquema parcial es desconocido.

## 26. Brechas y deuda técnica conocidas

1. No hay configuración externa por ambiente.
2. No hay logging persistente de consola ni rotación.
3. Download, validate y export no registran runs en `pipeline_runs`.
4. No hay scheduler ni alertas.
5. No hay cleanup automatizado de temporales.
6. No hay política automática de backup/restore.
7. No hay lock propio entre dos pipelines concurrentes.
8. Download no es transaccional como lote de siete archivos.
9. Export no es transaccional y puede mezclar generaciones.
10. El manifiesto público no se sincroniza automáticamente.
11. El build siempre reconstruye aunque `source_set_hash` no cambie.
12. `REQUIRED_BUILD_TABLES` no cubre las 35 tablas.
13. Agregar o renombrar un quality check exige actualizar también `EXPECTED_QUALITY_CHECKS`.
14. La confianza de calidad y el alcance temporal son conceptos separados; ambos deben comunicarse.
15. Tiempos por tabla se imprimen pero no se persisten.
16. No existen pruebas de concurrencia, disco lleno, permisos o recuperación de corrupción.
17. Las muestras CSV de 10.000 filas no sustituyen los marts completos del warehouse.
18. El PBIP se genera automáticamente, pero la creación final del PBIX todavía requiere Power BI Desktop.

## 27. Checklist de incidente

1. No borrar ni forzar nada inicialmente.
2. Capturar mensaje completo y comando ejecutado.
3. Confirmar procesos activos.
4. Confirmar montaje o enlace de `data/` y espacio disponible.
5. Consultar `pipeline_runs`.
6. Consultar `warehouse_state` y `snapshot_state`.
7. Determinar si la última publicación sigue válida.
8. Identificar stage exacto de falla.
9. Ejecutar diagnóstico de sólo lectura.
10. Corregir la causa mínima.
11. Repetir sólo el stage necesario.
12. Ejecutar validate y tests.
13. Regenerar export completo si algún archivo pudo quedar parcial.
14. Documentar causa, reparación y evidencia.

## 28. Checklist de publicación

- [ ] Python 3.11 y `pip check` correcto.
- [ ] `data/` existe, su enlace es válido si aplica y tiene espacio suficiente.
- [ ] Espacio suficiente en el volumen que contiene `data/`.
- [ ] Un ZIP por fecha.
- [ ] Hashes raw registrados.
- [ ] Siete snapshots activos consecutivos.
- [ ] Cero runs `running` huérfanos.
- [ ] Build con `--as-of` explícito.
- [ ] Cero gates altos.
- [ ] Linaje activo coincide con `build_inputs`.
- [ ] Tests y coverage pasan.
- [ ] Export completo sin excepciones.
- [ ] `run_metadata.json` referencia build publicado.
- [ ] Resumen sin `NaN`, `None` o rankings suprimidos.
- [ ] Documentación y Power BI alineados.
- [ ] Cambios revisados y committeados cuando corresponda.

## 29. Glosario

| Término | Definición |
|---|---|
| Snapshot | Corte diario nacional de SEPA. |
| Run de ingestión | Intento de activar una fecha raw. |
| Build | Construcción completa de marts para siete días. |
| `build_id` | Identidad de una publicación analítica. |
| `ingest_run_id` | Identidad de una versión ingerida. |
| GTIN | Identificador global de producto. |
| Código local | Identificador comparable sólo dentro de comercio/bandera. |
| Panel común | GTIN presentes en todas las cadenas del alcance en un día. |
| Benchmark geométrico | Media geométrica del precio entre cadenas para un GTIN. |
| Publicable | Supera el gate de cobertura del dominio. |
| Direccional | Cobertura parcial; sólo orientativo. |
| Suprimido | No debe entrar en rankings. |
| Raw | Archivo oficial sin modificar. |
| Spill | Archivos temporales usados por DuckDB al exceder memoria. |
| Lineage | Relación raw -> ingestión -> build -> output. |

## 30. Referencias del proyecto

- `README.md`: presentación y resultados.
- `docs/architecture.md`: arquitectura resumida.
- `docs/cleaning_log.md`: transformaciones y problemas visibles.
- `docs/data_dictionary.md`: diccionario resumido.
- `outputs/validation_report.md`: estado del build publicado.
- `outputs/resumen_ejecutivo.md`: interpretación de negocio.
- `powerbi/README.md`: diseño del reporte Power BI.
- `powerbi/measures.dax`: medidas DAX.
- `manifests/raw_sources.jsonl`: hashes raw públicos.
- Catálogo oficial: `https://datos.gob.ar/api/3/action/package_show?id=precios-claros-base-sepa`.

Este documento debe actualizarse cuando cambien versión de esquema, ventana, alcance de
cadenas, canasta, quality gates, rutas, dependencias o procedimientos de publicación.
