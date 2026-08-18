# Operación y publicación

## Principios

- Ejecutar siempre con Python 3.11 y una fecha de corte explícita.
- Tratar los ZIP raw como inmutables y verificar sus SHA-256.
- Mantener una sola escritura sobre el warehouse activo.
- No publicar si hay fallas de severidad alta o linaje incompleto.
- No convertir resultados `SUPPRESSED` en cero ni incorporarlos a rankings.
- No confundir el catálogo rotativo oficial con un archivo histórico.

## Preparación

Desde la raíz del repositorio:

```powershell
uv sync --extra dev --locked
uv pip check
uv run pytest -q
```

Antes de procesar datos, confirme espacio suficiente, acceso de escritura a `data/` y
ausencia de otro proceso Python o DuckDB que use el mismo warehouse. Los raw, temporales
y exports grandes pueden requerir varios gigabytes y no pertenecen a Git.

## Pipeline

La ejecución completa para un corte nuevo es:

```powershell
uv run pricing-canasta download
uv run pricing-canasta ingest --as-of <YYYY-MM-DD>
uv run pricing-canasta build --as-of <YYYY-MM-DD>
uv run pricing-canasta validate
uv run pricing-canasta export
```

En Windows, `scripts\run_all.bat` ejecuta todas las etapas desde un entorno `.venv`
ya instalado. Para un corte auditable se prefieren los comandos separados con `--as-of`.

| Etapa | Responsabilidad | Condición de éxito |
|---|---|---|
| `download` | Consulta catálogo, descarga y verifica ZIP. | Integridad ZIP y hashes válidos. |
| `ingest` | Sanea y carga cada snapshot en una transacción. | Reconciliación completa de filas. |
| `build` | Fija siete inputs y construye marts. | Cero fallas altas y publicación atómica. |
| `validate` | Revisa esquema, linaje, gates y confianza. | Informe consistente con el build activo. |
| `export` | Genera agregados y entregables ejecutivos. | Metadata escrita al finalizar. |

`download` obtiene los recursos que el catálogo ofrece en ese momento. Para reproducir
un corte histórico, omita esa suposición y provea los inputs exactos según
[`data_access.md`](data_access.md).

## Prepublicación

1. Confirme que la ventana tenga siete fechas consecutivas.
2. Compare hashes raw con el manifiesto correspondiente.
3. Ejecute pruebas y control de cobertura de código.
4. Ejecute `validate` y confirme cero fallas altas.
5. Revise advertencias medias, salud de fuente y entidades suprimidas.
6. Verifique que resumen, validación y metadata indiquen el mismo `build_id` y corte.
7. Compruebe que no se hayan exportado rutas locales, credenciales ni datos no previstos.

## Snapshot de publicación

`outputs/` contiene artefactos regenerables con nombres estables y puede sobrescribirse
en una ejecución posterior. Para conservar evidencia pública de un corte:

1. cree `reports/<YYYY-MM-DD>/` usando la fecha `as_of`;
2. copie como Markdown el resumen y el informe de validación ya generados;
3. añada un README con build, esquema, ventana, fecha de generación y procedencia;
4. conserve cifras, estados y advertencias sin reinterpretarlos;
5. no incluya raw, warehouse, rutas locales ni afirmaciones de archivo durable.

El snapshot de informe identifica una publicación analítica. No archiva los inputs raw
y no sustituye sus hashes.

## Controles posteriores

- Compare `outputs/run_metadata.json` con los encabezados del snapshot.
- Revise que Excel, HTML y CSV correspondan al mismo build.
- Busque valores inesperados como `None`, `NaN` o rankings de filas suprimidas.
- Confirme que los agregados versionados conservan `build_id` cuando el contrato lo exige.
- Registre por separado cualquier diferencia respecto del snapshot anterior.

## Recuperación

La ingestión por snapshot y el build son transaccionales: una falla debe conservar la
última versión publicada. Corrija la causa y repita la etapa; no edite manualmente
`snapshot_state`, `warehouse_state` ni los marts.

La exportación no es transaccional y puede dejar una mezcla de archivos si se interrumpe.
En ese caso, cierre consumidores como Excel o Power BI, resuelva el bloqueo y repita
`export` completo antes de publicar.

No elimine archivos `.part`, temporales o workdirs mientras haya procesos activos. No
trate raw, manifiestos o el warehouse publicado como temporales.

## Actualizaciones metodológicas

Un cambio de esquema, ventana, cadenas, canasta, fórmula o gate puede romper
comparabilidad. Debe incluir pruebas, documentación, evaluación de impacto y una nueva
versión cuando corresponda. Nunca relaje validaciones únicamente para hacer pasar un
corte con problemas.
