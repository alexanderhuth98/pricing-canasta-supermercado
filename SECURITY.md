# Política de seguridad

## Versiones soportadas

Se mantiene únicamente la versión más reciente de la rama principal. Los snapshots de
informes en `reports/` son registros de resultados y no reciben parches independientes.

## Reportar una vulnerabilidad

Use la función privada **Report a vulnerability** o **Private vulnerability reporting**
de la plataforma donde está alojado el repositorio. Incluya:

- componente y versión afectados;
- pasos mínimos para reproducir el problema;
- impacto y condiciones necesarias para explotarlo;
- prueba de concepto no destructiva, si corresponde;
- mitigación sugerida, si se conoce.

No publique una vulnerabilidad no corregida en un issue, discusión, pull request o
canal público. Si el repositorio no ofrece un canal privado, solicite al mantenedor que
lo habilite sin revelar detalles técnicos. La evaluación y respuesta se realizan según
disponibilidad; no se garantiza un plazo de respuesta.

## Alcance

Son especialmente relevantes:

- ejecución de código o escritura fuera de las rutas previstas mediante ZIP o CSV;
- validación insuficiente de descargas, hashes, nombres de archivo o contenido;
- inyección SQL o manipulación del warehouse mediante entradas no confiables;
- exposición de secretos, rutas locales o datos no destinados a publicación;
- dependencias vulnerables o compromiso de la cadena de suministro;
- alteración de linaje o publicación que permita presentar un build no validado como
  vigente.

Errores de calidad, cobertura o metodología sin impacto de seguridad deben reportarse
como issues ordinarios. Los precios publicados por comercios pueden ser incorrectos;
esa condición de la fuente no constituye por sí sola una vulnerabilidad del proyecto.

## Divulgación responsable

Evite acceder a datos ajenos, interrumpir servicios o descargar más información de la
necesaria para demostrar el problema. Conceda tiempo razonable para investigar y
corregir antes de divulgar. El proyecto procurará reconocer la contribución cuando la
persona reportante lo desee y la divulgación sea segura.
