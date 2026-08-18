param(
    [string]$ProjectRoot,
    [string]$DesktopBin,
    [switch]$PortableModel
)

$ErrorActionPreference = "Stop"

if ($env:POWERBI_PORTABLE_MODEL -eq "1") {
    $PortableModel = $true
}

$requiredAssemblies = @(
    "Microsoft.AnalysisServices.Server.Core.dll",
    "Microsoft.AnalysisServices.Server.Tabular.dll"
)

if (-not $DesktopBin) {
    $desktopCandidates = New-Object System.Collections.Generic.List[string]
    $desktopCommand = Get-Command "PBIDesktop.exe" -ErrorAction SilentlyContinue
    if ($desktopCommand) {
        $desktopCandidates.Add((Split-Path -Parent $desktopCommand.Source))
    }

    $desktopCandidates.Add((Join-Path $env:ProgramFiles "Microsoft Power BI Desktop\bin"))
    $appPackage = Get-AppxPackage -Name "Microsoft.MicrosoftPowerBIDesktop" `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($appPackage) {
        $desktopCandidates.Add((Join-Path $appPackage.InstallLocation "bin"))
    }

    foreach ($candidate in $desktopCandidates) {
        $missingAssemblies = @(
            $requiredAssemblies |
                Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidate $_)) }
        )
        if ($missingAssemblies.Count -eq 0) {
            $DesktopBin = $candidate
            break
        }
    }

    if (-not $DesktopBin) {
        throw "No se encontro Power BI Desktop con las dependencias TOM requeridas. Usa -DesktopBin."
    }
}

if (-not $ProjectRoot) {
    $ProjectRoot = if ($PSScriptRoot) {
        Split-Path -Parent $PSScriptRoot
    } else {
        (Get-Location).Path
    }
}

$dataRoot = Join-Path $ProjectRoot "portfolio_data"
$powerBiRoot = Join-Path $ProjectRoot "powerbi"
$semanticRoot = Join-Path $powerBiRoot "PricingCanasta.SemanticModel"
$reportRoot = Join-Path $powerBiRoot "PricingCanasta.Report"
$reportDefinition = Join-Path $reportRoot "definition"
$registeredResources = Join-Path $reportRoot "StaticResources\RegisteredResources"

foreach ($assembly in $requiredAssemblies) {
    $assemblyPath = Join-Path $DesktopBin $assembly
    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        throw "No se encontro la dependencia TOM: $assemblyPath"
    }
    Add-Type -Path $assemblyPath
}

if (-not (Test-Path -LiteralPath $dataRoot)) {
    throw "No se encontro portfolio_data: $dataRoot"
}

New-Item -ItemType Directory -Path $semanticRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportDefinition -Force | Out-Null
New-Item -ItemType Directory -Path $registeredResources -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $powerBiRoot "theme.json") `
    -Destination (Join-Path $registeredResources "PricingEditorial.json") -Force

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Test-AllLong {
    param([string[]]$Values)

    foreach ($value in $Values) {
        $parsed = 0L
        if (-not [long]::TryParse(
            $value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        )) {
            return $false
        }
    }
    return $true
}

function Test-AllDouble {
    param([string[]]$Values)

    foreach ($value in $Values) {
        $parsed = 0.0
        if (-not [double]::TryParse(
            $value,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        )) {
            return $false
        }
    }
    return $true
}

function Get-ColumnDefinition {
    param(
        [string]$Name,
        [object[]]$Records
    )

    $forcedText = @(
        "build_id",
        "scope_version",
        "basket_version",
        "gtin14",
        "provincia_codigo",
        "category_id",
        "id_comercio",
        "id_bandera"
    )
    $values = @(
        $Records |
            ForEach-Object { [string]$_.PSObject.Properties[$Name].Value } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($Name -eq "snapshot_date") {
        return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::DateTime; MType = "type date"; Format = "dd MMM yyyy" }
    }
    if ($Name -eq "failed_rows") {
        return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::Double; MType = "type number"; Format = "#,0" }
    }
    if ($forcedText -contains $Name -or $values.Count -eq 0) {
        return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::String; MType = "type text"; Format = $null }
    }
    if (($values | Where-Object { $_ -notin @("True", "False", "true", "false") }).Count -eq 0) {
        return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::Boolean; MType = "type logical"; Format = $null }
    }
    if (Test-AllLong -Values $values) {
        return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::Int64; MType = "Int64.Type"; Format = "0" }
    }
    if (Test-AllDouble -Values $values) {
        return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::Double; MType = "type number"; Format = "0.00" }
    }
    return @{ TomType = [Microsoft.AnalysisServices.Tabular.DataType]::String; MType = "type text"; Format = $null }
}

function Add-Measure {
    param(
        [Microsoft.AnalysisServices.Tabular.Table]$Table,
        [string]$Name,
        [string]$Expression,
        [string]$FormatString,
        [string]$Description
    )

    $measure = New-Object Microsoft.AnalysisServices.Tabular.Measure
    $measure.Name = $Name
    $measure.Expression = $Expression.Trim()
    if ($FormatString) {
        $measure.FormatString = $FormatString
    }
    if ($Description) {
        $measure.Description = $Description
    }
    $Table.Measures.Add($measure)
}

$database = New-Object Microsoft.AnalysisServices.Tabular.Database
$database.Name = "Pricing Canasta"
$database.ID = "PricingCanasta"
$database.CompatibilityLevel = 1606
$database.Model = New-Object Microsoft.AnalysisServices.Tabular.Model
$model = $database.Model
$model.Name = "Pricing Canasta"
$model.Culture = "es-AR"
$model.DefaultPowerBIDataSourceVersion = [Microsoft.AnalysisServices.Tabular.PowerBIDataSourceVersion]::PowerBI_V3

$dataFolder = New-Object Microsoft.AnalysisServices.Tabular.NamedExpression
$dataFolder.Name = "DataFolder"
$dataFolder.Kind = [Microsoft.AnalysisServices.Tabular.ExpressionKind]::M
$parameterPath = if ($PortableModel) {
    "<PORTFOLIO_DATA_PATH>\"
} else {
    $dataRoot.TrimEnd("\") + "\"
}
$dataFolder.Expression = '"' + $parameterPath.Replace('"', '""') + '" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]'
$dataFolder.Description = "Carpeta que contiene los CSV agregados de portfolio_data."
$model.Expressions.Add($dataFolder)

$csvTables = @(
    "index_daily",
    "index_7d",
    "index_sensitivity",
    "index_drivers",
    "basket_banner",
    "basket_province",
    "basket_definition",
    "basket_savings",
    "dispersion_entity",
    "source_health",
    "banner_health",
    "quality_checks"
)

$modelTables = @{}
$allDates = New-Object System.Collections.Generic.List[datetime]

foreach ($tableName in $csvTables) {
    $csvPath = Join-Path $dataRoot ($tableName + ".csv")
    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw "Falta la fuente requerida: $csvPath"
    }

    $records = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
    if ($records.Count -eq 0) {
        throw "La fuente no contiene filas: $csvPath"
    }

    $columnNames = @($records[0].PSObject.Properties.Name)
    $columnDefinitions = @{}
    foreach ($columnName in $columnNames) {
        $columnDefinitions[$columnName] = Get-ColumnDefinition -Name $columnName -Records $records
    }

    if ($columnNames -contains "snapshot_date") {
        foreach ($record in $records) {
            $parsedDate = [datetime]::MinValue
            if ([datetime]::TryParseExact(
                [string]$record.snapshot_date,
                "yyyy-MM-dd",
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsedDate
            )) {
                $allDates.Add($parsedDate.Date)
            }
        }
    }

    $table = New-Object Microsoft.AnalysisServices.Tabular.Table
    $table.Name = $tableName
    $table.Description = "Importado desde portfolio_data/$tableName.csv."

    foreach ($columnName in $columnNames) {
        $definition = $columnDefinitions[$columnName]
        $column = New-Object Microsoft.AnalysisServices.Tabular.DataColumn
        $column.Name = $columnName
        $column.SourceColumn = $columnName
        $column.DataType = $definition.TomType
        $column.SummarizeBy = [Microsoft.AnalysisServices.Tabular.AggregateFunction]::None
        if ($definition.Format) {
            $column.FormatString = $definition.Format
        }
        if ($columnName -in @("build_id", "scope_version", "basket_version", "id_comercio", "id_bandera")) {
            $column.IsHidden = $true
        }
        $table.Columns.Add($column)
    }

    $transformations = @(
        foreach ($columnName in $columnNames) {
            $escapedColumn = $columnName.Replace('"', '""')
            '{"' + $escapedColumn + '", ' + $columnDefinitions[$columnName].MType + '}'
        }
    ) -join ",`n        "

    $mExpression = @"
let
    Source = Csv.Document(File.Contents(DataFolder & "$tableName.csv"), [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]),
    PromotedHeaders = Table.PromoteHeaders(Source, [PromoteAllScalars=true]),
    TypedColumns = Table.TransformColumnTypes(
        PromotedHeaders,
        {
        $transformations
        },
        "en-US"
    )
in
    TypedColumns
"@

    $partition = New-Object Microsoft.AnalysisServices.Tabular.Partition
    $partition.Name = $tableName
    $partition.Mode = [Microsoft.AnalysisServices.Tabular.ModeType]::Import
    $partition.Source = New-Object Microsoft.AnalysisServices.Tabular.MPartitionSource
    $partition.Source.Expression = $mExpression.Trim()
    $table.Partitions.Add($partition)

    $model.Tables.Add($table)
    $modelTables[$tableName] = $table
}

if ($allDates.Count -eq 0) {
    throw "No se detectaron fechas para construir Calendario."
}

$minimumDate = ($allDates | Measure-Object -Minimum).Minimum
$maximumDate = ($allDates | Measure-Object -Maximum).Maximum
$calendarExpression = @"
let
    StartDate = #date($($minimumDate.Year), $($minimumDate.Month), $($minimumDate.Day)),
    EndDate = #date($($maximumDate.Year), $($maximumDate.Month), $($maximumDate.Day)),
    Dates = List.Dates(StartDate, Duration.Days(EndDate - StartDate) + 1, #duration(1, 0, 0, 0)),
    Source = Table.FromList(Dates, Splitter.SplitByNothing(), {"Fecha"}),
    Typed = Table.TransformColumnTypes(Source, {{"Fecha", type date}}),
    AddYear = Table.AddColumn(Typed, "Anio", each Date.Year([Fecha]), Int64.Type),
    AddMonthNumber = Table.AddColumn(AddYear, "Mes numero", each Date.Month([Fecha]), Int64.Type),
    AddMonth = Table.AddColumn(AddMonthNumber, "Mes", each Date.ToText([Fecha], "MMM", "es-AR"), type text),
    AddDay = Table.AddColumn(AddMonth, "Dia", each Date.ToText([Fecha], "ddd", "es-AR"), type text)
in
    AddDay
"@

$calendar = New-Object Microsoft.AnalysisServices.Tabular.Table
$calendar.Name = "Calendario"
$calendar.Description = "Dimension calendario compartida por todos los marts diarios."
$calendar.DataCategory = "Time"

$calendarColumns = @(
    @{ Name = "Fecha"; Type = [Microsoft.AnalysisServices.Tabular.DataType]::DateTime; Format = "yyyy-MM-dd" },
    @{ Name = "Anio"; Type = [Microsoft.AnalysisServices.Tabular.DataType]::Int64; Format = "0" },
    @{ Name = "Mes numero"; Type = [Microsoft.AnalysisServices.Tabular.DataType]::Int64; Format = "0" },
    @{ Name = "Mes"; Type = [Microsoft.AnalysisServices.Tabular.DataType]::String; Format = $null },
    @{ Name = "Dia"; Type = [Microsoft.AnalysisServices.Tabular.DataType]::String; Format = $null }
)
foreach ($definition in $calendarColumns) {
    $column = New-Object Microsoft.AnalysisServices.Tabular.DataColumn
    $column.Name = $definition.Name
    $column.SourceColumn = $definition.Name
    $column.DataType = $definition.Type
    $column.SummarizeBy = [Microsoft.AnalysisServices.Tabular.AggregateFunction]::None
    if ($definition.Format) {
        $column.FormatString = $definition.Format
    }
    $calendar.Columns.Add($column)
}
$calendar.Columns["Mes"].SortByColumn = $calendar.Columns["Mes numero"]

$calendarPartition = New-Object Microsoft.AnalysisServices.Tabular.Partition
$calendarPartition.Name = "Calendario"
$calendarPartition.Mode = [Microsoft.AnalysisServices.Tabular.ModeType]::Import
$calendarPartition.Source = New-Object Microsoft.AnalysisServices.Tabular.MPartitionSource
$calendarPartition.Source.Expression = $calendarExpression.Trim()
$calendar.Partitions.Add($calendarPartition)
$model.Tables.Add($calendar)

foreach ($tableName in $csvTables) {
    $table = $modelTables[$tableName]
    if ($table.Columns.Contains("snapshot_date")) {
        $relationship = New-Object Microsoft.AnalysisServices.Tabular.SingleColumnRelationship
        $relationship.Name = "Calendario_" + $tableName
        $relationship.FromColumn = $table.Columns["snapshot_date"]
        $relationship.FromCardinality = [Microsoft.AnalysisServices.Tabular.RelationshipEndCardinality]::Many
        $relationship.ToColumn = $calendar.Columns["Fecha"]
        $relationship.ToCardinality = [Microsoft.AnalysisServices.Tabular.RelationshipEndCardinality]::One
        $relationship.CrossFilteringBehavior = [Microsoft.AnalysisServices.Tabular.CrossFilteringBehavior]::OneDirection
        $relationship.IsActive = $true
        $model.Relationships.Add($relationship)
    }
}

$measures = New-Object Microsoft.AnalysisServices.Tabular.Table
$measures.Name = "Medidas"
$measures.Description = "Medidas ejecutivas y de calidad del reporte."
$measureColumn = New-Object Microsoft.AnalysisServices.Tabular.DataColumn
$measureColumn.Name = "Valor"
$measureColumn.SourceColumn = "Valor"
$measureColumn.DataType = [Microsoft.AnalysisServices.Tabular.DataType]::Int64
$measureColumn.IsHidden = $true
$measures.Columns.Add($measureColumn)
$measurePartition = New-Object Microsoft.AnalysisServices.Tabular.Partition
$measurePartition.Name = "Medidas"
$measurePartition.Mode = [Microsoft.AnalysisServices.Tabular.ModeType]::Import
$measurePartition.Source = New-Object Microsoft.AnalysisServices.Tabular.MPartitionSource
$measurePartition.Source.Expression = '#table(type table [Valor = Int64.Type], {{1}})'
$measures.Partitions.Add($measurePartition)
$model.Tables.Add($measures)

Add-Measure $measures "Indice precio" @'
MEDIAN('index_daily'[price_index])
'@ "0.00" "Indice relativo sobre el benchmark geometrico del panel comun."

Add-Measure $measures "GTIN comunes ultimo dia" @'
VAR Fecha = MAXX(ALL('index_daily'), 'index_daily'[snapshot_date])
RETURN
    CALCULATE(MIN('index_daily'[common_gtins]), 'index_daily'[snapshot_date] = Fecha)
'@ "#,0" "Menor cantidad de GTIN comunes entre cadenas en el ultimo corte disponible."

Add-Measure $measures "Indice semanal" @'
MEDIAN('index_7d'[geometric_mean_index])
'@ "0.00" "Mediana entre los indices geometricos por cadena en la ventana observada."

Add-Measure $measures "Sensibilidad maxima" @'
MAX('index_sensitivity'[sensitivity_delta])
'@ "0.00" "Mayor diferencia entre escenarios de sensibilidad."

Add-Measure $measures "Costo canasta ultimo corte" @'
VAR Fecha = MAXX(ALL('basket_banner'), 'basket_banner'[snapshot_date])
RETURN
    CALCULATE(
        MEDIAN('basket_banner'[branch_median_cost]),
        'basket_banner'[snapshot_date] = Fecha,
        'basket_banner'[coverage_status] = "PUBLISHABLE"
    )
'@ '$ #,0' "Mediana de los costos por cadena publicable en el ultimo corte."

Add-Measure $measures "Costo canasta provincia" @'
VAR Fecha = MAXX(ALL('basket_province'), 'basket_province'[snapshot_date])
RETURN
    CALCULATE(
        MEDIAN('basket_province'[branch_median_cost]),
        'basket_province'[snapshot_date] = Fecha,
        'basket_province'[coverage_status] = "PUBLISHABLE"
    )
'@ '$ #,0' "Costo mediano provincial publicable en el ultimo corte."

Add-Measure $measures "Sucursales canasta completa" @'
VAR Fecha = MAXX(ALL('basket_banner'), 'basket_banner'[snapshot_date])
RETURN
    CALCULATE(
        SUM('basket_banner'[complete_stores]),
        'basket_banner'[snapshot_date] = Fecha
    )
'@ "#,0" "Sucursales con los ocho componentes disponibles en el ultimo corte."

Add-Measure $measures "Completitud canasta" @'
VAR Fecha = MAXX(ALL('basket_banner'), 'basket_banner'[snapshot_date])
VAR Completas = CALCULATE(SUM('basket_banner'[complete_stores]), 'basket_banner'[snapshot_date] = Fecha)
VAR Activas = CALCULATE(SUM('basket_banner'[active_stores]), 'basket_banner'[snapshot_date] = Fecha)
RETURN
    DIVIDE(Completas, Activas)
'@ "0.0%" "Proporcion de sucursales activas con canasta completa en el ultimo corte."

Add-Measure $measures "Ahorro canasta" @'
VAR Fecha = MAXX(ALL('basket_savings'), 'basket_savings'[snapshot_date])
RETURN
    CALCULATE(
        MAX('basket_savings'[potential_saving_amount]),
        'basket_savings'[snapshot_date] = Fecha,
        'basket_savings'[comparison_level] = "BANNER"
    )
'@ '$ #,0' "Diferencia entre la cadena mas cara y la mas barata en el ultimo corte."

Add-Measure $measures "Ahorro canasta porcentaje" @'
VAR Fecha = MAXX(ALL('basket_savings'), 'basket_savings'[snapshot_date])
RETURN
    DIVIDE(
        CALCULATE(
            MAX('basket_savings'[potential_saving_pct]),
            'basket_savings'[snapshot_date] = Fecha,
            'basket_savings'[comparison_level] = "BANNER"
        ),
        100
    )
'@ "0.0%" "Ahorro porcentual potencial entre cadenas en el ultimo corte."

Add-Measure $measures "Salud cadena-dia" @'
VAR Fecha = MAXX(ALL('banner_health'), 'banner_health'[snapshot_date])
VAR Saludables =
    CALCULATE(
        COUNTROWS(FILTER('banner_health', 'banner_health'[source_healthy] = TRUE())),
        'banner_health'[snapshot_date] = Fecha
    )
VAR Total = CALCULATE(COUNTROWS('banner_health'), 'banner_health'[snapshot_date] = Fecha)
RETURN
    DIVIDE(Saludables, Total)
'@ "0.0%" "Porcentaje de cadenas saludables en el ultimo corte."

Add-Measure $measures "Cobertura tiendas" @'
MEDIAN('source_health'[store_coverage_ratio])
'@ "0.0%" "Cobertura mediana de tiendas reportantes."

Add-Measure $measures "Precios invalidos" @'
VAR Fecha = MAXX(ALL('source_health'), 'source_health'[snapshot_date])
RETURN
    CALCULATE(SUM('source_health'[invalid_list_price_rows]), 'source_health'[snapshot_date] = Fecha)
'@ "#,0" "Filas con precio de lista invalido en el ultimo corte."

Add-Measure $measures "Dispersion limpia" @'
VAR EsCadena = ISINSCOPE('dispersion_entity'[banner_label])
VAR Fecha =
    IF(
        EsCadena,
        MAXX(
            FILTER(
                ALL('dispersion_entity'),
                'dispersion_entity'[coverage_status] = "PUBLISHABLE"
                    && 'dispersion_entity'[dispersion_level] = "BANNER"
            ),
            'dispersion_entity'[snapshot_date]
        ),
        MAXX(
            FILTER(
                ALL('dispersion_entity'),
                'dispersion_entity'[coverage_status] = "PUBLISHABLE"
            ),
            'dispersion_entity'[snapshot_date]
        )
    )
RETURN
    IF(
        EsCadena,
        CALCULATE(
            MEDIAN('dispersion_entity'[median_dispersion_clean]),
            'dispersion_entity'[snapshot_date] = Fecha,
            'dispersion_entity'[coverage_status] = "PUBLISHABLE",
            'dispersion_entity'[dispersion_level] = "BANNER"
        ),
        CALCULATE(
            MEDIAN('dispersion_entity'[median_dispersion_clean]),
            'dispersion_entity'[snapshot_date] = Fecha,
            'dispersion_entity'[coverage_status] = "PUBLISHABLE"
        )
    )
'@ "0.0%" "Dispersion mediana del ultimo corte publicable luego de excluir precios criticos."

Add-Measure $measures "Productos dispersion publicables" @'
VAR Fecha =
    MAXX(
        FILTER(
            ALL('dispersion_entity'),
            'dispersion_entity'[coverage_status] = "PUBLISHABLE"
        ),
        'dispersion_entity'[snapshot_date]
    )
RETURN
    CALCULATE(
        SUM('dispersion_entity'[publishable_products]),
        'dispersion_entity'[snapshot_date] = Fecha,
        'dispersion_entity'[coverage_status] = "PUBLISHABLE"
    )
'@ "#,0" "Productos incluidos en entidades publicables del ultimo corte disponible."

Add-Measure $measures "Fallas altas" @'
CALCULATE(SUM('quality_checks'[failed_rows]), 'quality_checks'[severity] = "high")
'@ "#,0" "Filas fallidas en controles de severidad alta."

Add-Measure $measures "Contribucion driver top 3" @'
VAR Fecha = MAXX(ALL('index_drivers'), 'index_drivers'[snapshot_date])
RETURN
    CALCULATE(
        SUM('index_drivers'[contribution_log_points]),
        'index_drivers'[snapshot_date] = Fecha,
        KEEPFILTERS('index_drivers'[driver_rank] <= 3)
    )
'@ "0.000" "Contribucion logaritmica de los tres principales drivers del ultimo corte."

$serializeOptions = New-Object Microsoft.AnalysisServices.Tabular.SerializeOptions
$serializeOptions.IgnoreInferredProperties = $true
$serializeOptions.IgnoreInferredObjects = $true
$serializeOptions.IgnoreTimestamps = $true
$modelJson = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::SerializeDatabase($database, $serializeOptions)
$modelPath = Join-Path $semanticRoot "model.bim"
[System.IO.File]::WriteAllText($modelPath, $modelJson + [Environment]::NewLine, $utf8NoBom)

$validatedDatabase = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($modelJson)
if ($validatedDatabase.Model.Tables.Count -ne ($csvTables.Count + 2)) {
    throw "La validacion TOM devolvio un numero inesperado de tablas."
}

Write-JsonFile (Join-Path $semanticRoot "definition.pbism") ([ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json"
    version = "4.2"
    settings = @{}
})

Write-JsonFile (Join-Path $reportRoot "definition.pbir") ([ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json"
    version = "4.0"
    datasetReference = @{
        byPath = @{ path = "../PricingCanasta.SemanticModel" }
    }
})

Write-JsonFile (Join-Path $powerBiRoot "PricingCanasta.pbip") ([ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json"
    version = "1.0"
    artifacts = @(
        @{ report = @{ path = "PricingCanasta.Report" } }
    )
    settings = @{ enableAutoRecovery = $true }
})

Write-JsonFile (Join-Path $reportDefinition "report.json") ([ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/3.0.0/schema.json"
    themeCollection = @{
        baseTheme = @{
            name = "CY20SU09"
            reportVersionAtImport = @{ visual = "1.8.53"; report = "2.0.53"; page = "1.3.53" }
            type = "SharedResources"
        }
        customTheme = @{
            name = "PricingEditorial"
            reportVersionAtImport = @{ visual = "1.8.53"; report = "2.0.53"; page = "1.3.53" }
            type = "RegisteredResources"
        }
    }
    resourcePackages = @(
        @{
            name = "SharedResources"
            type = "SharedResources"
            items = @(
                @{ name = "CY20SU09"; path = "BaseThemes/CY20SU09.json"; type = "BaseTheme" }
            )
        },
        @{
            name = "RegisteredResources"
            type = "RegisteredResources"
            items = @(
                @{ name = "PricingEditorial"; path = "PricingEditorial.json"; type = "CustomTheme" }
            )
        }
    )
    settings = @{
        useStylableVisualContainerHeader = $true
        exportDataMode = "AllowSummarized"
        defaultDrillFilterOtherVisuals = $true
        allowChangeFilterTypes = $true
        useEnhancedTooltips = $true
    }
})

Write-JsonFile (Join-Path $reportDefinition "version.json") ([ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json"
    version = "2.0.0"
})

function New-ColumnField {
    param([string]$Table, [string]$Column)
    $displayNames = @{
        snapshot_date = "Fecha"
        banner_label = "Cadena"
        provincia_codigo = "Provincia"
        component_order = "Orden"
        category_name = "Categoría"
        canonical_product_name = "Producto"
        gtin14 = "GTIN"
        target_quantity_base = "Cantidad objetivo"
        target_base_unit = "Unidad"
        selection_rationale = "Justificación"
        severity = "Severidad"
        test_name = "Control"
        failed_rows = "Fallas"
        details = "Interpretación"
        driver_rank = "Posición"
        producto_descripcion = "Producto"
        marca = "Marca"
        product_relative_pct = "Diferencia vs benchmark (%)"
        contribution_log_points = "Contribución logarítmica"
    }
    $projection = @{
        field = @{ Column = @{ Expression = @{ SourceRef = @{ Entity = $Table } }; Property = $Column } }
        queryRef = "$Table.$Column"
    }
    if ($displayNames.ContainsKey($Column)) {
        $projection.displayName = $displayNames[$Column]
    }
    return $projection
}

function New-MeasureField {
    param([string]$Measure)
    return @{
        field = @{ Measure = @{ Expression = @{ SourceRef = @{ Entity = "Medidas" } }; Property = $Measure } }
        queryRef = "Medidas.$Measure"
    }
}

function New-MeasureSort {
    param([string]$Measure, [string]$Direction = "Descending")
    return @{
        sort = @(
            @{
                field = @{
                    Measure = @{
                        Expression = @{ SourceRef = @{ Entity = "Medidas" } }
                        Property = $Measure
                    }
                }
                direction = $Direction
            }
        )
        isDefaultSort = $true
    }
}

function New-TitleObjects {
    param([string]$Title)
    return @{
        title = @(
            @{
                properties = @{
                    show = @{ expr = @{ Literal = @{ Value = "true" } } }
                    text = @{ expr = @{ Literal = @{ Value = "'$Title'" } } }
                    fontSize = @{ expr = @{ Literal = @{ Value = "'12'" } } }
                    fontColor = @{ solid = @{ color = @{ expr = @{ Literal = @{ Value = "'#17324D'" } } } } }
                    alignment = @{ expr = @{ Literal = @{ Value = "'left'" } } }
                }
            }
        )
        background = @(
            @{ properties = @{ show = @{ expr = @{ Literal = @{ Value = "true" } } }; transparency = @{ expr = @{ Literal = @{ Value = "0D" } } } } }
        )
    }
}

$script:visualCounter = 0
function Add-Visual {
    param(
        [string]$PagePath,
        [string]$Type,
        [string]$Title,
        [hashtable]$QueryState,
        [double]$X,
        [double]$Y,
        [double]$Width,
        [double]$Height,
        [hashtable]$Objects = @{},
        [hashtable]$SortDefinition = $null
    )

    $script:visualCounter++
    $name = "{0:x20}" -f $script:visualCounter
    $visualDirectory = Join-Path (Join-Path $PagePath "visuals") $name
    New-Item -ItemType Directory -Path $visualDirectory -Force | Out-Null

    $query = @{ queryState = $QueryState }
    if ($SortDefinition) {
        $query.sortDefinition = $SortDefinition
    }

    $visual = [ordered]@{
        '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/2.2.0/schema.json"
        name = $name
        position = @{ x = $X; y = $Y; z = $script:visualCounter; width = $Width; height = $Height }
        visual = [ordered]@{
            visualType = $Type
            query = $query
            objects = $Objects
            visualContainerObjects = New-TitleObjects $Title
            drillFilterOtherVisuals = $true
        }
    }
    Write-JsonFile (Join-Path $visualDirectory "visual.json") $visual
}

function New-Page {
    param([string]$Name, [string]$DisplayName)

    $pagePath = Join-Path (Join-Path $reportDefinition "pages") $Name
    New-Item -ItemType Directory -Path (Join-Path $pagePath "visuals") -Force | Out-Null
    Write-JsonFile (Join-Path $pagePath "page.json") ([ordered]@{
        '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.0.0/schema.json"
        name = $Name
        displayName = $DisplayName
        displayOption = "FitToPage"
        height = 720
        width = 1280
    })
    return $pagePath
}

$cardObjects = @{
    categoryLabels = @(@{ properties = @{ show = @{ expr = @{ Literal = @{ Value = "false" } } } } })
    labels = @(@{ properties = @{
        fontSize = @{ expr = @{ Literal = @{ Value = "'24'" } } }
        labelDisplayUnits = @{ expr = @{ Literal = @{ Value = "1D" } } }
        color = @{ solid = @{ color = @{ expr = @{ Literal = @{ Value = "'#167D8D'" } } } } }
    } })
}

$currencyBarObjects = @{
    valueAxis = @(@{ properties = @{
        labelDisplayUnits = @{ expr = @{ Literal = @{ Value = "1D" } } }
    } })
}

$dateAxisObjects = @{
    categoryAxis = @(@{ properties = @{
        axisType = @{ expr = @{ Literal = @{ Value = "'Categorical'" } } }
    } })
}

$panorama = New-Page "Panorama" "Panorama ejecutivo"
Add-Visual $panorama "card" "GTIN comunes | último día" @{ Values = @{ projections = @(New-MeasureField "GTIN comunes ultimo dia") } } 30 25 280 125 $cardObjects
Add-Visual $panorama "card" "Cadenas saludables | último corte" @{ Values = @{ projections = @(New-MeasureField "Salud cadena-dia") } } 330 25 280 125 $cardObjects
Add-Visual $panorama "card" "Ahorro potencial | canasta" @{ Values = @{ projections = @(New-MeasureField "Ahorro canasta") } } 630 25 280 125 $cardObjects
Add-Visual $panorama "card" "Sensibilidad máxima | puntos de índice" @{ Values = @{ projections = @(New-MeasureField "Sensibilidad maxima") } } 930 25 280 125 $cardObjects
Add-Visual $panorama "lineChart" "Índice diario por cadena | 100 = centro del panel" @{
    Category = @{ projections = @(New-ColumnField "index_daily" "snapshot_date") }
    Series = @{ projections = @(New-ColumnField "index_daily" "banner_label") }
    Y = @{ projections = @(New-MeasureField "Indice precio") }
} 30 175 760 300 $dateAxisObjects
Add-Visual $panorama "clusteredBarChart" "Costo de canasta por cadena | último corte" @{
    Category = @{ projections = @(New-ColumnField "basket_banner" "banner_label") }
    Y = @{ projections = @(New-MeasureField "Costo canasta ultimo corte") }
} 815 175 395 300 $currencyBarObjects (New-MeasureSort "Costo canasta ultimo corte" "Ascending")
Add-Visual $panorama "lineChart" "Tiendas reportantes vs mediana 7d" @{
    Category = @{ projections = @(New-ColumnField "source_health" "snapshot_date") }
    Y = @{ projections = @(New-MeasureField "Cobertura tiendas") }
} 30 500 1180 185 $dateAxisObjects

$basket = New-Page "Canasta" "Canasta fija"
Add-Visual $basket "card" "Costo mediano | último corte" @{ Values = @{ projections = @(New-MeasureField "Costo canasta ultimo corte") } } 30 25 280 125 $cardObjects
Add-Visual $basket "card" "Ahorro potencial" @{ Values = @{ projections = @(New-MeasureField "Ahorro canasta porcentaje") } } 330 25 280 125 $cardObjects
Add-Visual $basket "card" "Sucursales completas" @{ Values = @{ projections = @(New-MeasureField "Sucursales canasta completa") } } 630 25 280 125 $cardObjects
Add-Visual $basket "card" "Completitud" @{ Values = @{ projections = @(New-MeasureField "Completitud canasta") } } 930 25 280 125 $cardObjects
Add-Visual $basket "clusteredBarChart" "Canasta publicable por cadena" @{
    Category = @{ projections = @(New-ColumnField "basket_banner" "banner_label") }
    Y = @{ projections = @(New-MeasureField "Costo canasta ultimo corte") }
} 30 175 570 260 $currencyBarObjects (New-MeasureSort "Costo canasta ultimo corte" "Ascending")
Add-Visual $basket "clusteredBarChart" "Canasta publicable por provincia" @{
    Category = @{ projections = @(New-ColumnField "basket_province" "provincia_codigo") }
    Y = @{ projections = @(New-MeasureField "Costo canasta provincia") }
} 620 175 590 260 $currencyBarObjects (New-MeasureSort "Costo canasta provincia" "Ascending")
Add-Visual $basket "tableEx" "Definición auditable de la canasta" @{
    Values = @{ projections = @(
        (New-ColumnField "basket_definition" "component_order"),
        (New-ColumnField "basket_definition" "category_name"),
        (New-ColumnField "basket_definition" "canonical_product_name"),
        (New-ColumnField "basket_definition" "gtin14"),
        (New-ColumnField "basket_definition" "target_quantity_base"),
        (New-ColumnField "basket_definition" "target_base_unit"),
        (New-ColumnField "basket_definition" "selection_rationale")
    ) }
} 30 460 1180 225 @{}

$quality = New-Page "Calidad" "Calidad y cobertura"
Add-Visual $quality "card" "Fallas de severidad alta" @{ Values = @{ projections = @(New-MeasureField "Fallas altas") } } 30 25 280 125 $cardObjects
Add-Visual $quality "card" "Precios inválidos | último corte" @{ Values = @{ projections = @(New-MeasureField "Precios invalidos") } } 330 25 280 125 $cardObjects
Add-Visual $quality "card" "Dispersión limpia | último corte publicable" @{ Values = @{ projections = @(New-MeasureField "Dispersion limpia") } } 630 25 280 125 $cardObjects
Add-Visual $quality "card" "Conteos producto-entidad | último corte publicable" @{ Values = @{ projections = @(New-MeasureField "Productos dispersion publicables") } } 930 25 280 125 $cardObjects
Add-Visual $quality "lineChart" "Tiendas reportantes vs mediana 7d" @{
    Category = @{ projections = @(New-ColumnField "source_health" "snapshot_date") }
    Y = @{ projections = @(New-MeasureField "Cobertura tiendas") }
} 30 175 570 260 $dateAxisObjects
Add-Visual $quality "clusteredBarChart" "Dispersión por cadena | último corte publicable" @{
    Category = @{ projections = @(New-ColumnField "dispersion_entity" "banner_label") }
    Y = @{ projections = @(New-MeasureField "Dispersion limpia") }
} 620 175 590 260 @{} (New-MeasureSort "Dispersion limpia" "Descending")
Add-Visual $quality "tableEx" "Controles de calidad del build publicado" @{
    Values = @{ projections = @(
        (New-ColumnField "quality_checks" "severity"),
        (New-ColumnField "quality_checks" "test_name"),
        (New-ColumnField "quality_checks" "failed_rows"),
        (New-ColumnField "quality_checks" "details")
    ) }
} 30 460 1180 225 @{}

$drivers = New-Page "Drivers" "Drivers y sensibilidad"
Add-Visual $drivers "card" "Índice semanal mediano" @{ Values = @{ projections = @(New-MeasureField "Indice semanal") } } 30 25 280 125 $cardObjects
Add-Visual $drivers "card" "Sensibilidad máxima" @{ Values = @{ projections = @(New-MeasureField "Sensibilidad maxima") } } 330 25 280 125 $cardObjects
Add-Visual $drivers "clusteredBarChart" "Top 3 drivers del último corte" @{
    Category = @{ projections = @(New-ColumnField "index_drivers" "producto_descripcion") }
    Series = @{ projections = @(New-ColumnField "index_drivers" "banner_label") }
    Y = @{ projections = @(New-MeasureField "Contribucion driver top 3") }
} 30 175 570 260 @{} (New-MeasureSort "Contribucion driver top 3" "Descending")
Add-Visual $drivers "lineChart" "Sensibilidad diaria por cadena" @{
    Category = @{ projections = @(New-ColumnField "index_sensitivity" "snapshot_date") }
    Series = @{ projections = @(New-ColumnField "index_sensitivity" "banner_label") }
    Y = @{ projections = @(New-MeasureField "Sensibilidad maxima") }
} 620 175 590 260 $dateAxisObjects
Add-Visual $drivers "tableEx" "Detalle de drivers" @{
    Values = @{ projections = @(
        (New-ColumnField "index_drivers" "banner_label"),
        (New-ColumnField "index_drivers" "driver_rank"),
        (New-ColumnField "index_drivers" "gtin14"),
        (New-ColumnField "index_drivers" "producto_descripcion"),
        (New-ColumnField "index_drivers" "marca"),
        (New-ColumnField "index_drivers" "product_relative_pct"),
        (New-ColumnField "index_drivers" "contribution_log_points")
    ) }
} 30 460 1180 225 @{}

$pagesPath = Join-Path $reportDefinition "pages"
Write-JsonFile (Join-Path $pagesPath "pages.json") ([ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.0.0/schema.json"
    pageOrder = @("Panorama", "Canasta", "Calidad", "Drivers")
    activePageName = "Panorama"
})

Write-Output "PBIP generado: $(Join-Path $powerBiRoot 'PricingCanasta.pbip')"
Write-Output "Modelo validado: $($validatedDatabase.Model.Tables.Count) tablas, $($validatedDatabase.Model.Relationships.Count) relaciones, $($measures.Measures.Count) medidas."
