# Avisos

## Software

Copyright (c) 2026 Alexander Huth.

El software y la documentación original de este repositorio se distribuyen bajo la
licencia MIT incluida en [`LICENSE`](LICENSE).

## Fuente de datos

Este proyecto utiliza y transforma **Precios Claros - Base SEPA**, publicado por la
Subsecretaría de Defensa del Consumidor y Lealtad Comercial de la República Argentina
bajo [Creative Commons Attribution 4.0
International](https://creativecommons.org/licenses/by/4.0/).

- [Catálogo oficial](https://datos.gob.ar/api/3/action/package_show?id=precios-claros-base-sepa)
- [Página oficial del dataset](https://datos.produccion.gob.ar/dataset/sepa-precios)
- [Especificación técnica](https://datos.produccion.gob.ar/dataset/6f47ec76-d1ce-4e34-a7e1-621fe9b1d0b5/resource/ace44eb9-c995-463f-bf8a-6f529d196a27/download/anexo_6201340_2.pdf)

Las transformaciones del proyecto incluyen validación estructural, normalización de
GTIN y unidades, separación de códigos de alcance local, controles de cobertura,
tratamiento explícito de anomalías y agregación analítica. Consulte
[`DATA_LICENSE.md`](DATA_LICENSE.md) para las condiciones de reutilización.

Este es un proyecto independiente. No está afiliado, patrocinado ni aprobado por el
organismo publicador, Precios Claros, SEPA ni los comercios mencionados. Los errores u
opiniones del análisis pertenecen al proyecto y no a la fuente.

Los datos raw históricos no se distribuyen en Git y este aviso no implica que exista
un archivo histórico durable mantenido por el proyecto.
