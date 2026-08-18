# Metodología pública

## Objetivo y unidad de análisis

El proyecto compara precios publicados por cadenas y provincias usando productos
exactamente equivalentes. La ventana publicada cubre siete snapshots diarios. El grano
comparable es:

```text
fecha + comercio + bandera + sucursal + GTIN
```

Los resultados describen la red de sucursales observada. No estiman precios pagados,
participación de mercado, gasto de hogares ni inflación.

## Fuente y preparación

La fuente es [Precios Claros - Base
SEPA](https://datos.produccion.gob.ar/dataset/sepa-precios), publicada bajo CC BY 4.0.
Cada ZIP nacional contiene archivos de comercios, sucursales y productos. La ingestión:

1. verifica tamaño, estructura ZIP, fecha, CRC y SHA-256;
2. exige el encabezado y número de campos del contrato SEPA;
3. elimina BOM, bytes NUL, líneas vacías y el footer técnico;
4. reconstruye sólo continuaciones físicas conocidas y vuelve a validar el esquema;
5. conserva identificadores como texto y convierte valores con tipado tolerante;
6. reconcilia filas fuente y cargadas antes de activar el snapshot.

No se rellenan silenciosamente columnas faltantes. Los valores inválidos permanecen
visibles para poder medir su incidencia.

## Comparabilidad de productos

Un producto entra en comparaciones entre comercios sólo si está marcado como EAN, tiene
longitud 8, 12, 13 o 14 y supera el dígito verificador al normalizarse a GTIN-14. Los
códigos internos y los restringidos `20-29` se conservan con alcance local, pero nunca
se cruzan entre comercios.

Los precios de lista, promociones generales y promociones segmentadas permanecen
separados. Los indicadores publicados en este análisis utilizan precio de lista válido,
sin imputación de faltantes.

## Índice relativo de precios

Para cada día se exige que las siete cadenas estén saludables y se usa la intersección
de GTIN presentes en todas ellas. El precio de cada cadena y producto es la mediana de
sus sucursales.

Para producto `g`, cadena `b` y día `t`:

```text
benchmark(g,t) = exp(promedio_b(ln(precio(b,g,t))))
relativo(b,g,t) = precio(b,g,t) / benchmark(g,t)
indice(b,t) = 100 * exp(promedio_g(ln(relativo(b,g,t))))
```

Cada cadena pesa lo mismo en el benchmark y cada GTIN pesa lo mismo en el índice. El
centro geométrico diario debe ser 100 y la publicación exige al menos 500 GTIN comunes.
El indicador no está ponderado por ventas ni consumo.

## Canasta fija

La versión `CANASTA_2026W31_V1` contiene ocho GTIN fijos:

| Categoría | GTIN-14 | Presentación |
|---|---|---|
| Aceite | `07790272001029` | 1,5 L |
| Arroz | `07791120031557` | 1 kg |
| Azúcar | `07792540250450` | 1 kg |
| Café | `07790550022234` | 250 g |
| Fideos | `07790070320285` | 500 g |
| Harina | `07790070562258` | 1 kg |
| Leche | `07790742363008` | 1 L |
| Yerba | `07792710000182` | 500 g |

Sólo las sucursales con los ocho componentes entran en estadísticas de costo completo.
No se sustituyen GTIN, no se escalan presentaciones y no se imputan faltantes. Los
agregados por cadena o provincia se publican únicamente al superar sus umbrales de
cobertura.

## Dispersión y anomalías

La dispersión se calcula como:

```text
dispersion = (P90 - P10) / mediana
```

La versión `clean` excluye observaciones con anomalías críticas. Se detectan valores
transversales o saltos temporales fuera de un factor `0,5-2`, y posibles errores de
escala cercanos a potencias de diez. Excluir un dato crítico no corrige ni reemplaza el
precio original.

Los resultados reciben estado `PUBLISHABLE`, `DIRECTIONAL` o `SUPPRESSED` según tiendas,
cadenas y productos cubiertos. Las filas suprimidas no se convierten en cero ni entran
en rankings.

## Calidad, linaje y publicación

Cada build fija siete fechas consecutivas, los runs de ingestión y los hashes raw. La
publicación se bloquea ante fallas altas como pérdida de filas, esquema incompatible,
claves comparables nulas, códigos locales en el hecho global, panel desigual, centro
geométrico incorrecto o canasta inválida.

Las advertencias medias mantienen visibles precios inválidos, GTIN inválidos, geografía
incompleta, paquetes vacíos conocidos, reconstrucciones, anomalías y baja salud de
fuente. El nivel de confianza resume calidad, frescura y salud; no amplía la profundidad
histórica.

## Interpretación y límites

- Siete días permiten describir el corte, no medir inflación, estacionalidad o una
  ventaja estructural.
- La fuente contiene precios informados por comercios y puede incluir errores o faltantes.
- El índice representa un panel común con ponderación uniforme, no todo el surtido.
- La canasta representa ocho presentaciones exactas, no una canasta de consumo oficial.
- El resultado nacional no se pondera por población, facturación ni tamaño de cadena.
- Una fecha reciente puede no ser publicable si no supera los gates de cobertura.

La definición técnica completa de tablas y contratos permanece en
[`documentacion_tecnica_completa.md`](documentacion_tecnica_completa.md).
