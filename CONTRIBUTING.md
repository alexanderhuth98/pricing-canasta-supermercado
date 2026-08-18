# Contribuir

Las contribuciones que mejoran corrección, auditabilidad y claridad son bienvenidas.
Antes de proponer cambios, revise la metodología y las reglas de publicación en
[`docs/methodology.md`](docs/methodology.md) y [`docs/operations.md`](docs/operations.md).

## Formas de contribuir

- Corregir errores reproducibles en descarga, ingestión, cálculo o exportación.
- Añadir pruebas para contratos de datos, métricas y casos límite.
- Mejorar documentación sin debilitar las limitaciones ni la atribución.
- Proponer controles de calidad con una regla, severidad y justificación explícitas.
- Reportar problemas de seguridad por el canal privado indicado en
  [`SECURITY.md`](SECURITY.md).

## Preparar el entorno

Se requiere Python 3.11.

```powershell
uv sync --extra dev --locked
uv run ruff check src tests
uv run pytest --cov=pricing_canasta --cov-report=term-missing --cov-fail-under=80
```

Las pruebas unitarias no requieren descargar los snapshots históricos. Para datos,
almacenamiento y límites de reproducción, consulte [`docs/data_access.md`](docs/data_access.md).

## Proponer un cambio

1. Abra una discusión o issue para cambios metodológicos, de esquema o de alcance.
2. Mantenga el cambio pequeño y acompañado por pruebas relevantes.
3. Ejecute la suite completa y el control de cobertura.
4. Actualice la documentación cuando cambien contratos, métricas o operación.
5. Describa el efecto observable, los riesgos y la validación realizada.

Una propuesta no debe reducir umbrales, ocultar advertencias, imputar faltantes ni
mezclar códigos locales entre comercios sólo para producir un ranking. Los cambios en
la canasta, cadenas, ventana, esquema o gates requieren una nueva versión metodológica
cuando alteren comparabilidad.

## Datos en contribuciones

- No incluya ZIP raw, warehouses, archivos temporales ni exportaciones masivas.
- No incluya secretos, credenciales, datos personales añadidos ni rutas locales.
- No sustituya los hashes del manifiesto sin documentar procedencia y validación.
- Use fixtures mínimos, sintéticos o suficientemente reducidos para las pruebas.
- Mantenga la atribución a Precios Claros - Base SEPA y señale las transformaciones.
- No afirme que un recurso histórico está archivado si sólo existe un hash o una URL
  rotativa.

## Estilo y calidad

- Preserve Python 3.11 y las versiones fijadas por el proyecto.
- Trate identificadores como texto y conserve ceros iniciales.
- Añada un test de regresión para cada corrección de cálculo o contrato.
- Mantenga cero fallas de severidad alta antes de publicar resultados.
- Evite conclusiones causales, de inflación o tendencia basadas en la ventana de siete
  días.

## Licencias de contribuciones

Al enviar una contribución, declara que tiene derecho a hacerlo y acepta que el código
y la documentación original se distribuyan bajo MIT. Los datos y contenidos derivados
de Precios Claros - Base SEPA permanecen sujetos a CC BY 4.0 y a la atribución descrita
en [`DATA_LICENSE.md`](DATA_LICENSE.md).
