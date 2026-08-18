# Resumen ejecutivo

> **Snapshot identificado.** Corte `2026-08-02`; ventana `2026-07-27` a
> `2026-08-02`; build `941da9b2-93b6-40b8-8de8-c9e27ad03e10`; esquema `2.0.0`.
> Copia de publicación basada en `outputs/resumen_ejecutivo.md`.

## Objetivo

Comparar nivel de precios, dispersion y costo de una canasta exacta sin mezclar
catalogos, presentaciones ni codigos locales.

## Hallazgos cuantificados

1. **Nivel de precios:** sobre 634 GTIN comunes, Hipermercado Carrefour presento el indice mas bajo (96.98) y Jumbo el mas alto (103.36). La diferencia es descriptiva del panel comun, no de todo el surtido.
2. **Dispersion por cadena:** ninguna cadena alcanzo cobertura publicable en el ultimo corte.
3. **Dispersion geografica:** ninguna provincia alcanzo cobertura publicable en el ultimo corte. Tampoco hubo combinaciones cadena-provincia publicables.
4. **Ahorro potencial de canasta:** entre cadenas publicables, la brecha es $5,163 (15.1%). Entre provincias, $3,048 (9.6%).
5. **Robustez y fuente:** excluir precios criticos cambio los indices como maximo 0.47 puntos. Hubo 1 dia nacional debajo del umbral de salud; esos cortes se identifican visualmente y no prueban cambios comerciales.

## Acciones de negocio

1. El responsable de pricing debe revisar primero los 15 drivers de mayor contribucion de cada cadena y confirmar si son decisiones comerciales o errores de escala.
2. Category management debe usar `basket_candidate_review.csv` para evaluar sustituciones; la canasta publicada no cambia automaticamente.
3. Las provincias y combinaciones con estado `SUPPRESSED` no deben aparecer en rankings; se requiere ampliar sucursales antes de decidir.
4. Para negociar precios, priorizar GTIN con dispersion alta persistente durante varios dias y no picos de una sola fecha.
5. Archivar al menos 28 dias antes de formular conclusiones estructurales o de tendencia.

## Limitaciones especificas

- El indice mide un panel comun con igual peso por producto y cadena; no representa participacion de mercado ni gasto del consumidor.
- La dispersion P90-P10 describe precios publicados, no promociones ni precios efectivamente pagados.
- El ahorro de canasta existe solo donde los ocho GTIN estan presentes; no se imputan faltantes.
- El dato nacional es la red de sucursales observada y no una estimacion ponderada por poblacion.
- Siete dias permiten describir el corte, no medir inflacion, estacionalidad o superioridad estructural.

## Procedencia

Datos derivados de [Precios Claros - Base
SEPA](https://datos.produccion.gob.ar/dataset/sepa-precios), bajo CC BY 4.0. Este
snapshot conserva resultados agregados; no contiene ni afirma archivar los raw
históricos.
