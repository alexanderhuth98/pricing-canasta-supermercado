# Cleaning log

## Transformaciones documentadas

1. Se conserva cada ZIP oficial con fecha interna, tamaño y SHA-256.
2. Se elimina el BOM del encabezado al reemplazarlo por un encabezado canónico.
3. Se eliminan bytes NUL porque rompen el parser y no representan contenido válido.
4. Se excluye únicamente la línea técnica `Última actualización`, que no es un registro.
5. Las líneas completamente vacías se ignoran; una línea con datos nunca se rellena con `NULL`.
6. Siete archivos de sucursales de Comodín traen registros partidos en continuaciones que
   empiezan con `|`. Se reconstruyeron 560 líneas y cada registro final se validó contra 21 campos.
7. Los archivos ausentes, paquetes vacíos, reconstrucciones y diferencias de filas se registran en `ingestion_log`.
8. Los identificadores se recortan y conservan como texto.
9. Los campos vacíos se convierten en `NULL`.
10. Las fechas, coordenadas, cantidades y precios se convierten con `TRY_CAST`.
11. Las unidades se normalizan sin modificar la cantidad declarada.
12. Las descripciones se normalizan sólo para clasificación; la original se conserva.
13. Un GTIN se considera comparable sólo si el indicador EAN es verdadero, su longitud es válida y pasa el dígito verificador.
14. Los códigos `20-29` y códigos internos reciben alcance local, nunca global.
15. Los precios no positivos permanecen en el hecho con `precio_lista_valido = false`.

## Problemas que permanecen visibles

- Un comercio puede faltar en un snapshot.
- Un paquete puede estar vacío o contener datos desactualizados.
- La descripción o marca puede variar para un mismo GTIN.
- La presentación estructurada puede declarar `1 UN` aunque otra variante del mismo GTIN
  confirme gramos o mililitros; la canasta exige evidencia observada de la presentación objetivo.
- La fuente no garantiza la veracidad comercial de los precios.
- El histórico disponible inicialmente cubre sólo siete días.

## Ready for analysis

Los marts se publican sólo cuando `quality_checks` no contiene fallas altas, existen los ocho
componentes fijos, el panel del índice es consistente y las siete fechas tienen linaje completo.
Las advertencias medias reducen la confianza y permanecen visibles en el informe.
