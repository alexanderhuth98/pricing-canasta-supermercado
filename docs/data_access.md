# Acceso a datos y reproducibilidad

## Fuente oficial

El proyecto usa snapshots nacionales de **Precios Claros - Base SEPA**, publicados por
la Subsecretaría de Defensa del Consumidor y Lealtad Comercial de la República
Argentina.

- [Catálogo nacional](https://datos.gob.ar/api/3/action/package_show?id=precios-claros-base-sepa)
- [Página oficial del dataset](https://datos.produccion.gob.ar/dataset/sepa-precios)
- [Especificación técnica SEPA](https://datos.produccion.gob.ar/dataset/6f47ec76-d1ce-4e34-a7e1-621fe9b1d0b5/resource/ace44eb9-c995-463f-bf8a-6f529d196a27/download/anexo_6201340_2.pdf)
- [Licencia CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

El catálogo publica recursos por día de la semana y los reemplaza con datos recientes.
Una URL oficial que hoy descarga un archivo no garantiza recuperar el contenido que
tenía en una fecha anterior.

## Qué contiene Git

| Material | Incluido | Uso |
|---|---|---|
| Código, SQL y pruebas | Sí | Revisión y pruebas automatizadas. |
| Manifiesto de inputs | Sí | Fechas, tamaños y SHA-256 del corte conocido. |
| CSV agregados | Sí | Verificación de resultados y Power BI. |
| Informes del corte | Sí | Evidencia legible del build y sus quality gates. |
| ZIP raw nacionales | No | Entrada pesada y sujeta a rotación oficial. |
| Warehouse DuckDB | No | Artefacto reconstruible sólo con los inputs exactos. |
| Parquet y temporales masivos | No | Artefactos derivados o de trabajo. |

`manifests/raw_sources.jsonl` permite comprobar que un archivo obtenido por otra vía es
idéntico al usado por el build. Un hash demuestra identidad cuando se dispone del
archivo; no almacena el contenido y no demuestra que exista una copia accesible.

## Niveles de reproducción

### 1. Pruebas del software

Un clon nuevo puede instalar dependencias y ejecutar la suite sin los raw históricos:

```powershell
uv sync --extra dev --locked
uv run pytest -q
uv run pytest --cov=pricing_canasta --cov-report=term-missing --cov-fail-under=80
```

Las pruebas cubren contratos CSV, descarga, GTIN, ingestión transaccional, matemática de
métricas, build, exportación y CLI.

### 2. Verificación de resultados agregados

Los CSV pequeños de `portfolio_data/`, el manifiesto y el snapshot de
`reports/2026-08-02/` permiten revisar de forma reproducible:

- identidad del build, esquema y ventana;
- conteos reconciliados y resultados de quality gates;
- panel común, índices, sensibilidad y drivers;
- definición y resultados agregados de canasta;
- salud de fuente, cobertura y estados `PUBLISHABLE` o `SUPPRESSED`.

Esta verificación trabaja sobre artefactos agregados versionados. No equivale a repetir
la ingestión de 97.485.870 filas desde cero.

### 3. Reconstrucción histórica completa

Para reconstruir exactamente el corte `2026-08-02`, hacen falta los siete ZIP
inmutables de `2026-07-27` a `2026-08-02`, con tamaños y SHA-256 iguales a
`manifests/raw_sources.jsonl`. Después deben ubicarse bajo el layout relativo
`data/raw/YYYY-MM-DD/` y ejecutarse las etapas con fecha explícita:

```powershell
uv run pricing-canasta ingest --as-of 2026-08-02
uv run pricing-canasta build --as-of 2026-08-02
uv run pricing-canasta validate
uv run pricing-canasta export
```

Una descarga nueva desde el catálogo rotativo puede producir otra semana y otros
hashes. Por eso, un clon nuevo no puede asumir reproducción histórica completa sólo
con `download`. Se necesita un archivo externo, inmutable y verificable de los inputs
exactos. Este proyecto no afirma que dicho archivo durable exista.

## Verificación de integridad

En PowerShell, compare el SHA-256 de cada ZIP con el manifiesto:

```powershell
Get-FileHash -Algorithm SHA256 .\data\raw\2026-08-02\sepa_domingo.zip
```

No ingiera un archivo si fecha, tamaño o hash no coinciden con la versión que pretende
reproducir. Un contenido diferente debe tratarse como otro input y, si se publica,
generar un build distinto con linaje propio.

## Licencia y atribución

Los datos y resultados derivados se rigen por CC BY 4.0; el código y la documentación
original, por MIT. Consulte [`DATA_LICENSE.md`](../DATA_LICENSE.md) para el alcance y el
texto de atribución recomendado.
