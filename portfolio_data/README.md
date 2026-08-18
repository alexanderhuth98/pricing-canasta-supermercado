# Datasets de portfolio

CSV agregados y regenerables para revision, demostraciones y Power BI. Todos los datasets
canonicos incluyen `build_id`; no contienen el hecho completo de 97,5 millones de filas.

## Calidad e indice

- `quality_daily.csv`, `quality_checks.csv`, `source_health.csv`, `banner_health.csv`;
- `index_daily.csv`, `index_7d.csv`, `index_sensitivity.csv`, `index_drivers.csv`;
- `banner_overlap.csv`.

## Canasta

- `basket_definition.csv`, `basket_candidate_review.csv`;
- `basket_banner.csv`, `basket_province.csv`, `basket_banner_province.csv`;
- `basket_national.csv`, `basket_savings.csv`.

## Dispersion y anomalias

- `dispersion_entity.csv` contiene el resumen por entidad y estado de cobertura;
- `dispersion_product_sample.csv` se genera localmente con hasta 10.000 filas no suprimidas;
- `price_anomalies_sample.csv` se genera localmente con hasta 10.000 filas, priorizando
  las críticas.

Los archivos con sufijo `_sample` no representan exportaciones completas y están fuera
del historial público por volumen y nivel de detalle. Los Parquet completos o de mayor
volumen se guardan en `data/exports/`, también fuera de Git.

La allowlist de `.gitignore` limita la publicación a agregados defendibles. Los CSV
versionados no incluyen direcciones, coordenadas, CUIT ni observaciones de sucursal.

Los archivos legacy sin `build_id` se eliminan durante cada export para evitar que un
consumidor mezcle metodologias o cortes incompatibles.
