# Licencia y atribución de datos

Este repositorio combina software propio con datos y resultados derivados de una
fuente pública. Las condiciones aplicables dependen del material reutilizado.

## Código y documentación original

El código fuente, las pruebas y la documentación original del proyecto se publican
bajo la licencia MIT incluida en [`LICENSE`](LICENSE).

La licencia MIT no sustituye ni modifica la licencia de los datos de terceros.

## Datos y resultados derivados

Los registros de precios, metadatos de la fuente y datos derivados de **Precios
Claros - Base SEPA** se reutilizan conforme a **Creative Commons Attribution 4.0
International (CC BY 4.0)**. Esto incluye las métricas, tablas y extractos derivados
de la fuente que se encuentren en `portfolio_data/`, `outputs/`, `reports/` y
`manifests/`, en la medida en que expresen o reproduzcan información de la fuente.

CC BY 4.0 permite compartir y adaptar el material para cualquier propósito, incluso
comercial, siempre que se otorgue atribución adecuada, se enlace la licencia y se
indique si se realizaron cambios. Consulte el [texto oficial de CC BY
4.0](https://creativecommons.org/licenses/by/4.0/).

## Atribución solicitada

Al reutilizar datos o resultados derivados, use una atribución equivalente a:

> Fuente: Precios Claros - Base SEPA, Subsecretaría de Defensa del Consumidor y
> Lealtad Comercial, República Argentina, bajo CC BY 4.0. Datos transformados por el
> proyecto Pricing y canasta de supermercado; las modificaciones incluyen validación,
> normalización, filtrado, agregación y cálculo de indicadores.

Fuentes oficiales:

- [Catálogo nacional de Precios Claros - Base SEPA](https://datos.gob.ar/api/3/action/package_show?id=precios-claros-base-sepa)
- [Página oficial del dataset](https://datos.produccion.gob.ar/dataset/sepa-precios)
- [Especificación técnica SEPA](https://datos.produccion.gob.ar/dataset/6f47ec76-d1ce-4e34-a7e1-621fe9b1d0b5/resource/ace44eb9-c995-463f-bf8a-6f529d196a27/download/anexo_6201340_2.pdf)

La atribución al proyecto no debe sugerir aprobación, patrocinio ni autoría de los
resultados por parte del organismo fuente o de los comercios informantes.

## Disponibilidad y conservación

Los ZIP raw y el warehouse no se incluyen en Git. El catálogo oficial publica
recursos diarios rotativos y no garantiza que una fecha histórica concreta siga
disponible. `manifests/raw_sources.jsonl` registra fechas, tamaños y SHA-256 de los
inputs usados, pero no contiene los datos ni representa un archivo histórico
durable.

Un clon nuevo sólo puede reconstruir íntegramente el corte histórico si el usuario
obtiene por separado copias inmutables de los siete inputs exactos y verifica sus
hashes. Este repositorio no afirma que exista actualmente un archivo durable de esos
inputs. Las pruebas del software y la verificación de los resultados agregados
versionados no requieren los raw históricos; consulte [`docs/data_access.md`](docs/data_access.md).

## Otros derechos

CC BY 4.0 no concede derechos sobre marcas, logotipos ni otros elementos que puedan
estar sujetos a derechos independientes. Los nombres de organismos y comercios se
usan únicamente con fines de identificación y análisis. Quien reutilice el material
es responsable de evaluar los derechos aplicables a su uso concreto.
