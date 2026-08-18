# Diccionario de datos

## fact_price

| Campo | Descripción |
|---|---|
| snapshot_date | Fecha interna del ZIP oficial. |
| source_package | ZIP del comercio que originó el registro. |
| id_comercio | Identificador SEPA del comercio. |
| id_bandera | Identificador de la bandera comercial. |
| id_sucursal | Identificador de sucursal dentro del comercio/bandera. |
| id_producto | GTIN o código interno declarado. |
| productos_ean | Indica si la fuente declara que el identificador es EAN/GTIN. |
| gtin14 | Identificador normalizado a 14 dígitos. |
| gtin_valido | Resultado de validar formato y dígito verificador. |
| product_code_scope | `GLOBAL_GTIN`, `RESTRICTED_LOCAL`, `INTERNAL_LOCAL` o `INVALID`. |
| producto_descripcion | Descripción original. |
| producto_descripcion_normalizada | Descripción sin acentos y en mayúsculas. |
| cantidad_presentacion | Cantidad del envase declarado. |
| unidad_presentacion | Unidad normalizada (`G`, `KG`, `ML`, `L`, `UN`). |
| marca | Marca declarada. |
| precio_lista | Precio sin promociones ni segmentación. |
| precio_referencia | Precio para la cantidad/unidad de referencia. |
| precio_promo_general | Promoción de alcance general. |
| precio_promo_segmentada | Promoción condicionada por segmento o medio de pago. |
| precio_lista_valido | Precio de lista informado y mayor que cero. |

## Marts

| Tabla | Propósito |
|---|---|
| mart_quality_daily | Volumen, cobertura GTIN y validez de precios por día. |
| mart_price_product_daily | Distribución por producto, bandera, provincia y fecha. |
| mart_banner_day_health | Cobertura y salud por cadena/día. |
| mart_product_persistence_7d | Persistencia condicional y calendario de cada GTIN. |
| mart_banner_index_daily | Índice común diario centrado geométricamente en 100. |
| mart_banner_index_7d | Resumen geométrico de siete días por cadena. |
| mart_banner_index_driver_daily | Contribución de cada GTIN al índice. |
| mart_banner_index_sensitivity_daily | Índice raw, sin críticos y winsorizado. |
| mart_basket_candidate_review | Evidencia semántica y de presentación por candidato. |
| dim_basket_component | Ocho GTIN exactos de la versión publicada. |
| mart_basket_store_daily | Costo observado y cobertura por sucursal/día. |
| mart_basket_banner_daily | Canasta por cadena sobre sucursales completas. |
| mart_basket_province_daily | Canasta por provincia con gates de cobertura. |
| mart_basket_national_daily | Red nacional observada, no ponderada por población. |
| mart_price_dispersion_daily | P10, mediana, P90 y dispersión raw/limpia por cuatro niveles. |
| mart_dispersion_entity_daily | Resumen y estado publicable por entidad geográfica/comercial. |
| quality_price_anomaly_daily | Outliers transversales y saltos temporales. |
| quality_checks | Gates altos y advertencias medias del build publicado. |

## Capa semántica Power BI

| Objeto | Definición |
|---|---|
| `DataFolder` | Parámetro M que apunta a `portfolio_data/`. |
| `Calendario` | Dimensión diaria compartida por los nueve marts con `snapshot_date`. |
| `Medidas` | Tabla técnica que concentra 17 medidas ejecutivas. |
| `Dispersion limpia` | Mediana de `median_dispersion_clean` en la última fecha que tenga entidades `PUBLISHABLE`. |
| `Productos dispersion publicables` | Suma de `publishable_products` por entidad en esa misma fecha; representa conteos producto-entidad, no GTIN únicos nacionales. |

La fecha de dispersión se calcula dentro de las filas publicables. En el build
`941da9b2-93b6-40b8-8de8-c9e27ad03e10` es `2026-07-31`; el `2026-08-02` permanece
`SUPPRESSED` y no participa en estas medidas.
