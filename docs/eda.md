# Análisis exploratorio de datos

## Executive Summary

El análisis exploratorio cubre siete snapshots nacionales de Precios Claros entre el
27 de julio y el 2 de agosto de 2026. Se analizaron 97.485.870 observaciones de precio,
78.705 GTIN globales y 3.054 sucursales identificables.

La fuente es suficientemente amplia para comparar un panel común de siete cadenas y
una canasta fija. Sin embargo, la cobertura no es uniforme: el 1 de agosto cae a 10,4
millones de filas y 1.719 sucursales, frente a aproximadamente 14,2-14,8 millones de
filas y 2.648-3.030 sucursales en los otros días. Esa pérdida explica que sólo cinco de
los siete días sean comparables para el índice.

## Objectives

1. Medir volumen, cobertura temporal, comercial y geográfica.
2. Cuantificar códigos comparables, locales e inválidos.
3. Revisar missing values, precios inválidos y duplicados.
4. Caracterizar la distribución de precios y detectar outliers.
5. Evaluar estabilidad del índice y sensibilidad a extremos.
6. Identificar limitaciones antes de producir rankings.

## Methodology

- Fuente: siete ZIP oficiales archivados e inmutables.
- Precio analítico: precio de lista positivo; promociones separadas.
- Producto comparable: GTIN válido según formato y dígito verificador.
- Duplicado global: misma fecha, comercio, bandera, sucursal y GTIN.
- Precio por cadena/GTIN: mediana entre sucursales.
- Percentiles exploratorios globales: `approx_quantile` sobre 94,6 millones de precios.
- Outlier crítico: ratio transversal o temporal fuera del intervalo 0,5-2.
- Cobertura saludable: al menos 80% de filas y sucursales respecto de la mediana semanal.

## KPIs

| KPI | Resultado |
|---|---:|
| Observaciones fuente | 97.485.870 |
| Observaciones `GLOBAL_GTIN` | 94.553.421 (97,0%) |
| Observaciones `RESTRICTED_LOCAL` | 2.729.439 (2,8%) |
| Observaciones `INTERNAL_LOCAL` | 197.414 (0,2%) |
| Códigos declarados EAN inválidos | 5.596 |
| Precios de lista inválidos | 392 |
| GTIN distintos | 78.705 |
| Sucursales distintas | 3.054 |
| Provincias válidas `AR-*` | 24 |
| Duplicados del grano global | 0 |
| Anomalías críticas | 2.336 |
| Salud cadena-día | 47/49 (95,9%) |
| Días con índice comparable | 5/7 |

## Coverage by Day

| Fecha | Filas fuente | Sucursales | GTIN globales | Filas globales | Salud |
|---|---:|---:|---:|---:|---|
| 2026-07-27 | 14.504.541 | 2.698 | 75.705 | 14.064.692 | Saludable |
| 2026-07-28 | 14.178.832 | 2.698 | 75.602 | 13.745.984 | Saludable |
| 2026-07-29 | 14.496.441 | 2.648 | 77.365 | 14.057.927 | Saludable |
| 2026-07-30 | 14.823.531 | 3.030 | 77.958 | 14.384.739 | Saludable |
| 2026-07-31 | 14.489.621 | 2.702 | 77.139 | 14.050.984 | Saludable |
| 2026-08-01 | 10.364.387 | 1.719 | 76.031 | 10.062.108 | No saludable |
| 2026-08-02 | 14.628.517 | 2.966 | 76.098 | 14.186.987 | Saludable |

La correlación entre filas fuente y sucursales informantes es `0,963`. El volumen diario
depende principalmente de cuántas sucursales reportan, no sólo de cambios de catálogo.
Por eso un descenso de filas no debe interpretarse automáticamente como baja de productos.

## Price Distribution

Percentiles aproximados del precio de lista global válido:

| Percentil | Precio aproximado |
|---|---:|
| P01 | $558 |
| P10 | $1.513 |
| P50 | $4.422 |
| P90 | $19.903 |
| P99 | $256.870 |
| Media | $16.297 |

La media es 3,7 veces la mediana y P99 es casi 58 veces P50. La distribución tiene una
cola derecha extrema, esperable al mezclar categorías y presentaciones muy diferentes.
Esto justifica usar medianas, percentiles y relativos por GTIN en lugar de promedios
directos de precios absolutos.

## Missing Values and Invalid Data

- No se detectaron claves nulas dentro del hecho global comparable.
- Se separaron 5.596 códigos EAN que no superaron formato o checksum.
- Sólo 392 precios de lista fueron nulos, cero, negativos o no numéricos.
- Se registraron 258 filas de dimensión con geografía ausente o no normalizada.
- Siete paquetes vacíos conocidos permanecen visibles como advertencia.
- Se reconstruyeron 560 continuaciones físicas de sucursales sin pérdida de filas.

Los registros problemáticos no se eliminan de `fact_price`; reciben flags o alcances que
los excluyen de comparaciones inadecuadas y permiten auditarlos.

## Duplicate Analysis

No existen duplicados en el grano:

```text
fecha + comercio + bandera + sucursal + GTIN
```

para filas globales con precio válido. El build vuelve a comprobar esta condición antes
de proyectar `fct_global_price_store_daily`; una duplicación futura bloquea la publicación.

## Segmentation

### Product-code scope

- `GLOBAL_GTIN`: 97,0% de observaciones; aptas para comparación entre comercios.
- `RESTRICTED_LOCAL`: 2,8%; códigos de peso/uso restringido, sólo análisis local.
- `INTERNAL_LOCAL`: 0,2%; códigos internos no EAN.
- `INVALID`: 0,006%; declarados EAN pero inválidos.

### Index scope

El índice compara siete banderas fijas. En el último día comparable, 31 de julio, el
panel contiene 634 GTIN comunes:

| Cadena | Índice |
|---|---:|
| Hipermercado Carrefour | 96,98 |
| DIA | 97,26 |
| COTO | 97,86 |
| Changomas | 98,80 |
| La Anónima | 102,88 |
| Cooperativa Obrera | 103,12 |
| Jumbo | 103,36 |

En el promedio geométrico de los cinco días comparables, DIA queda primero con 96,38 y
Carrefour segundo con 96,89. La cadena más barata no fue idéntica en todos los cortes;
por eso se muestran tendencia y resumen semanal, no un único ranking aislado.

### Basket scope

Al 2 de agosto, entre cadenas con al menos 20 sucursales completas:

- Vea: $29.109, menor mediana observada.
- HiperChangomas: $34.272, mayor mediana observada.
- Diferencia: $5.163, equivalente al 15,1% del costo más alto.

La comparación usa exactamente los mismos ocho GTIN y excluye sucursales incompletas.

## Outlier and Sensitivity Analysis

Se identificaron 2.336 anomalías críticas en el universo analítico. Para evaluar si
distorsionaban el ranking se comparó el índice raw con una variante que excluye relativos
fuera de 0,5-2.

El cambio máximo fue 0,47 puntos, observado en Changomas el 28 de julio. La dirección
general del ranking es robusta, aunque los productos extremos deben revisarse antes de
atribuir la diferencia a una decisión comercial.

Ejemplos de drivers del último día comparable:

| Cadena | Producto | Relativo frente al benchmark |
|---|---|---:|
| Carrefour | Jabón en barra aloe/oliva | +38,9% |
| Carrefour | Café Dolca origen | -26,4% |
| Jumbo | Jugo sabor naranja | +31,9% |
| Jumbo | Gaseosa cola lata | +28,6% |

Estas contribuciones son descriptivas; una revisión comercial debe confirmar descripción,
presentación y precio fuente antes de actuar.

## Geographic Dispersion

Ninguna cadena, provincia o combinación cadena-provincia alcanzó el mínimo de 100
productos publicables en el último corte. El dashboard muestra “Sin cobertura publicable”
en lugar de fabricar un ranking con muestras insuficientes.

Este resultado es un hallazgo de calidad: para responder sólidamente dónde existe mayor
dispersión territorial se necesita ampliar cobertura o historia, no reducir el gate sin evidencia.

El reporte Power BI separa “último corte calendario” de “último corte publicable”. El
`02/08` conserva sus filas como `SUPPRESSED`; las tarjetas de dispersión retroceden de
forma explícita al `31/07`, última fecha con entidades `PUBLISHABLE`. Allí la mediana de
dispersión limpia es `3,4%` y la suma de coberturas por entidad alcanza `29.812`
observaciones producto-entidad. Estos valores resumen entidades publicables y no habilitan
un ranking para el `02/08`.

## Key Findings

1. El 97,0% de las observaciones pertenece a GTIN globales comparables.
2. La cobertura del 1 de agosto cae 36% en sucursales respecto de aproximadamente 2.700,
   lo que reduce los días comparables del índice a cinco.
3. Carrefour es la cadena de menor índice en el último día comparable, pero DIA lidera
   el promedio semanal; el liderazgo no es totalmente estable.
4. La canasta comparable presenta una brecha de $5.163 o 15,1% entre extremos publicables.
5. Excluir precios extremos mueve el índice como máximo 0,47 puntos.
6. La dispersión geográfica no tiene cobertura suficiente para un ranking responsable.

## Business Recommendations

1. Usar el índice semanal y la tendencia antes que un único día para decisiones de pricing.
2. Revisar los 15 drivers principales por cadena para separar estrategia de errores de escala.
3. Priorizar disponibilidad de los ocho GTIN en sucursales con baja completitud de canasta.
4. No usar rankings territoriales hasta alcanzar cobertura publicable.
5. Archivar al menos 28 días para evaluar persistencia, no sólo descripción semanal.

## Next Analyses

1. Extender el histórico a 28-90 días para tendencia y estabilidad.
2. Analizar elasticidad o promociones cuando exista información de ventas.
3. Construir cohortes de sucursales estables para separar cobertura de cambio de precio.
4. Revisar categorías y presentaciones que concentran anomalías críticas.
5. Incorporar ponderaciones de consumo sólo si existe una fuente defendible.
