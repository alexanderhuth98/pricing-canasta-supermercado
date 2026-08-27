# Power BI

## Objetivo y audiencia

- Objetivo: comparar nivel de precios, costo de la canasta, cobertura y riesgos de calidad.
- Audiencia: dirección comercial, pricing y category management.
- Grano ejecutivo: cadena/día y provincia/día; detalle auditable de drivers hasta GTIN.
- Regla: ningún visual convierte filas `SUPPRESSED` en rankings.

## Fuentes

Importar los CSV de `portfolio_data/` con tipos explícitos:

| Tabla | Uso |
|---|---|
| `index_daily.csv` | Índice diario por cadena y panel común. |
| `index_7d.csv` | Resumen ejecutivo semanal. |
| `index_sensitivity.csv` | Robustez frente a precios críticos. |
| `index_drivers.csv` | Drill-through por GTIN. |
| `basket_banner.csv` | Costo y cobertura de canasta por cadena. |
| `basket_province.csv` | Canasta provincial. |
| `basket_definition.csv` | Ocho componentes fijos. |
| `basket_savings.csv` | Ahorro potencial entre cadenas y provincias. |
| `dispersion_entity.csv` | Dispersión por nivel y estado de cobertura. |
| `source_health.csv` | Salud nacional diaria. |
| `banner_health.csv` | Salud cadena/día. |
| `quality_checks.csv` | Gates y advertencias del build. |

No cargar `fact_price` ni Parquet de detalle en Power BI Desktop. El modelo debe usar
Import sobre estas tablas agregadas. Crear una tabla `Calendario` y relacionar
`Calendario[Fecha]` uno-a-muchos con cada `snapshot_date`; mantener desactivadas las
relaciones ambiguas entre hechos.

## Páginas

### 1. Panorama ejecutivo

- KPI: GTIN comunes, salud cadena/día, ahorro potencial y sensibilidad máxima.
- Tendencia: línea del índice por cadena; el título explicita que 100 es el centro del panel.
- Desglose: barras de costo mediano de canasta, sólo `coverage_status = PUBLISHABLE`.
- Nota visible: panel común, igual peso, red observada y ventana de siete días.

### 2. Canasta fija

- KPI: costo mediano, ahorro porcentual, sucursales completas y tasa de completitud.
- Tendencia: costo mediano por cadena y fecha.
- Desglose: provincia y cadena-provincia, siempre filtrando estados publicables.
- Tabla: ocho GTIN, presentación objetivo y evidencia auditada.

### 3. Calidad y cobertura

- KPI: fallas altas, precios inválidos, dispersión limpia y productos-entidad publicables.
- Tendencia: cobertura nacional y salud por cadena.
- Desglose: dispersión limpia por entidad sólo cuando `coverage_status = PUBLISHABLE`.
- Tabla: quality gates con severidad, fallas e interpretación.

![Calidad y cobertura en Power BI](../docs/images/powerbi_calidad.png)

### Regla temporal de dispersión

El `02/08/2026` contiene filas de dispersión, pero todas están `SUPPRESSED`. Por eso las
medidas no deben tomar simplemente `MAX(snapshot_date)` y luego filtrar estados: esa
combinación produce `(en blanco)`.

`Dispersion limpia` y `Productos dispersion publicables` calculan primero la fecha máxima
dentro del subconjunto `PUBLISHABLE`. Para este build es el `31/07/2026`:

```dax
VAR Fecha =
    MAXX(
        FILTER(
            ALL(dispersion_entity),
            dispersion_entity[coverage_status] = "PUBLISHABLE"
        ),
        dispersion_entity[snapshot_date]
    )
```

Después aplican esa fecha y el mismo estado al cálculo. El resultado es `3,4%` de
dispersión limpia mediana y `29.812` conteos producto-entidad. Esta regla es un fallback
explícito al último corte publicable; no reclasifica el `02/08`, no convierte suprimidos en
cero y no habilita rankings territoriales sin cobertura.

### 4. Drivers y sensibilidad

- Matriz: cadena, fecha, ranking, GTIN, descripción y contribución logarítmica.
- El gráfico conserva cadena y producto en el grano para no agregar descripciones entre cadenas.
- La tabla expone GTIN, posición, diferencia contra benchmark y contribución.

## Interacciones

- Los gráficos aplican cross-filter nativo entre visuales de la misma página.
- El panel de filtros permite acotar los campos presentes; la versión actual no incorpora
  slicers dedicados ni una página de drill-through.
- Las tendencias respetan el contexto de fecha y cadena; las tarjetas de último corte
  documentan explícitamente qué fecha seleccionan.
- Los rankings excluyen `SUPPRESSED`; no reemplazar faltantes por cero.
- Los tooltips actuales son los predeterminados del visual. Tooltips enriquecidos,
  botón de reset y layout móvil PBIR quedan como mejoras futuras, no funcionalidades actuales.

## Diseño

- `theme.json` se registra como tema personalizado `PricingEditorial` durante la generación.
- El reporte usa base marfil, tarjetas en azul petróleo y rojo sólo para fallas.
- Mantener una sola familia tipográfica y máximo siete series por gráfico.
- Formatos: índice `0.00`, porcentajes `0.0%`, moneda `$ #,##0`, GTIN como texto.

## Artefactos disponibles

- `PricingCanasta.pbip`: entrada del proyecto editable.
- `PricingCanasta.Report/`: definición PBIR de cuatro páginas y 26 visuales.
- `PricingCanasta.SemanticModel/model.bim`: modelo TMSL con 14 tablas, 9 relaciones y 17 medidas.
- `PricingCanasta.pbix`: copia binaria validada, distribuida como activo de GitHub Release
  y excluida del historial Git.
- `build_pbip.ps1`: generador reproducible del PBIP a partir de `portfolio_data/`.
- `validate_pbip.ps1`: valida JSON, contratos CSV, referencias visuales y el modelo TOM.

![Panorama ejecutivo en Power BI](../docs/images/powerbi_panorama.png)

## Reconstrucción

Desde la raíz del repositorio:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\powerbi\build_pbip.ps1
```

Si una política corporativa `AllSigned` invalida `Bypass`, ejecutar el script por entrada
estándar sin modificar la política del equipo:

```powershell
cmd.exe /d /c "type powerbi\build_pbip.ps1 | powershell.exe -NoProfile -Command -"
```

El generador detecta Power BI Desktop y sus ensamblados TOM sin fijar una versión de
Microsoft Store. Infiere tipos conservadores, conserva GTIN y claves como texto, crea el
parámetro M `DataFolder` y valida `model.bim` con TOM antes de terminar. Si la detección
automática falla, se puede indicar `-DesktopBin <ruta-al-binario-de-desktop>`.

Validar el PBIP versionado sin modificarlo:

```powershell
powershell.exe -NoProfile -File .\powerbi\validate_pbip.ps1
```

Con una política corporativa `AllSigned`, usar la misma entrada estándar segura que para
el generador:

```powershell
cmd.exe /d /c "type powerbi\validate_pbip.ps1 | powershell.exe -NoProfile -Command -"
```

El comando comprueba JSON, marcador portable, esquema y tipos de los CSV, referencias de
visuales, páginas, tablas, relaciones y medidas; después deserializa `model.bim` con TOM.
En CI, donde Power BI Desktop no está disponible, `-SkipTom` conserva todos los controles
estáticos y omite únicamente la deserialización con ensamblados de Desktop.

El `model.bim` versionado usa `<PORTFOLIO_DATA_PATH>` para no publicar rutas personales.
Ejecutar el generador sin `PortableModel` después de clonar reemplaza ese marcador por la
ruta local de `portfolio_data/`. Los mantenedores regeneran la versión portable con:

```powershell
$env:POWERBI_PORTABLE_MODEL = "1"
cmd.exe /d /c "type powerbi\build_pbip.ps1 | powershell.exe -NoProfile -Command -"
Remove-Item Env:POWERBI_PORTABLE_MODEL
```

## Apertura y actualización

1. Abrir `PricingCanasta.pbip` con Power BI Desktop.
2. Seleccionar **Actualizar** en la cinta **Inicio** para importar los CSV.
3. Al guardar, elegir **No actualizar** si Desktop ofrece convertir TMSL a TMDL; así se conserva `model.bim` como fuente reproducible.
4. Usar **Archivo > Guardar como > Examinar este dispositivo** y seleccionar `Archivo de Power BI (*.pbix)` para regenerar el binario.

La validación realizada con Power BI Desktop `2.156.951.0` produjo:

| Control | Resultado |
|---|---:|
| Tablas | 14 |
| Relaciones activas | 9 |
| Medidas | 17 |
| Filas `index_daily` | 35 |
| Filas `basket_banner` | 174 |
| Filas `quality_checks` | 25 |
| GTIN comunes, último día | 634 |
| Ahorro potencial | $ 5.163 |
| Salud cadena/día | 85,7% |
| Fallas altas | 0 |
| Último corte de dispersión publicable | 31/07/2026 |
| Dispersión limpia mediana | 3,4% |
| Conteos producto-entidad publicables | 29.812 |

`95,9%` es la salud acumulada de la semana (`47/49` cadenas-día). El `85,7%` de la
tarjeta corresponde al último corte (`6/7`) y no reemplaza ese indicador semanal.

Versionar PBIP, PBIR, `model.bim` y el generador. Los directorios `.pbi/` contienen
caché y configuración local y están ignorados. Antes de publicar, reconciliar los KPI
contra `reports/2026-08-02/`. El build esperado es
`941da9b2-93b6-40b8-8de8-c9e27ad03e10`.
