param(
    [string]$DesktopBin,
    [switch]$SkipTom
)

$ErrorActionPreference = "Stop"
trap {
    Write-Error $_
    exit 1
}

if ($env:POWERBI_SKIP_TOM -eq "1") {
    $SkipTom = $true
}

$powerBiRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Join-Path (Get-Location).Path "powerbi"
}
$projectRoot = Split-Path -Parent $powerBiRoot
$dataRoot = Join-Path $projectRoot "portfolio_data"
$modelPath = Join-Path $powerBiRoot "PricingCanasta.SemanticModel\model.bim"
$pagesRoot = Join-Path $powerBiRoot "PricingCanasta.Report\definition\pages"

$requiredSources = @(
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

$jsonFiles = New-Object System.Collections.Generic.List[string]
[System.IO.Directory]::EnumerateFiles(
    $powerBiRoot,
    "*.json",
    [System.IO.SearchOption]::AllDirectories
) | ForEach-Object { $jsonFiles.Add($_) }

@(
    (Join-Path $powerBiRoot "PricingCanasta.pbip"),
    (Join-Path $powerBiRoot "PricingCanasta.Report\.platform"),
    (Join-Path $powerBiRoot "PricingCanasta.Report\definition.pbir"),
    (Join-Path $powerBiRoot "PricingCanasta.SemanticModel\.platform"),
    (Join-Path $powerBiRoot "PricingCanasta.SemanticModel\definition.pbism"),
    $modelPath
) | ForEach-Object { $jsonFiles.Add($_) }

foreach ($path in $jsonFiles) {
    $null = [System.IO.File]::ReadAllText($path) |
        ConvertFrom-Json -ErrorAction Stop
}

$modelText = [System.IO.File]::ReadAllText($modelPath)
if ([regex]::IsMatch($modelText, '(?i)[A-Z]:[\\/]')) {
    throw "model.bim contiene una ruta absoluta."
}

$modelDefinition = $modelText | ConvertFrom-Json
$dataFolder = @(
    $modelDefinition.model.expressions |
        Where-Object { $_.name -eq "DataFolder" }
)
if (
    $dataFolder.Count -ne 1 -or
    -not $dataFolder[0].expression.StartsWith('"<PORTFOLIO_DATA_PATH>\')
) {
    throw "DataFolder no conserva el marcador portable esperado."
}

$modelTables = @{}
foreach ($table in $modelDefinition.model.tables) {
    if ($modelTables.ContainsKey($table.name)) {
        throw "Tabla duplicada en el modelo: $($table.name)"
    }
    $columns = @{}
    foreach ($column in $table.columns) {
        $columns[$column.name] = $true
    }
    $measures = @{}
    foreach ($measure in $table.measures) {
        $measures[$measure.name] = $true
    }
    $modelTables[$table.name] = @{ Columns = $columns; Measures = $measures }
}

$rowCounts = @{}
foreach ($tableName in $requiredSources) {
    $csvPath = Join-Path $dataRoot ($tableName + ".csv")
    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw "Falta la fuente requerida: $tableName.csv"
    }
    if (-not $modelTables.ContainsKey($tableName)) {
        throw "Falta la tabla requerida en el modelo: $tableName"
    }

    $records = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
    if ($records.Count -eq 0) {
        throw "La fuente no contiene filas: $tableName.csv"
    }
    $rowCounts[$tableName] = $records.Count

    $csvColumns = @($records[0].PSObject.Properties.Name)
    $tableDefinition = @(
        $modelDefinition.model.tables |
            Where-Object { $_.name -eq $tableName }
    )[0]
    $sourceColumns = @($tableDefinition.columns.sourceColumn)
    $missing = @($sourceColumns | Where-Object { $_ -notin $csvColumns })
    if ($missing.Count -gt 0) {
        throw "Columnas ausentes en $tableName.csv: $($missing -join ', ')"
    }

    foreach ($column in $tableDefinition.columns) {
        if ($column.dataType -eq "string") {
            continue
        }
        for ($rowIndex = 0; $rowIndex -lt $records.Count; $rowIndex++) {
            $value = [string]$records[$rowIndex].PSObject.Properties[$column.sourceColumn].Value
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $isValid = $false
            if ($column.dataType -eq "int64") {
                $parsedInteger = 0L
                $isValid = [long]::TryParse(
                    $value,
                    [System.Globalization.NumberStyles]::Integer,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsedInteger
                )
            } elseif ($column.dataType -eq "double") {
                $parsedDouble = 0.0
                $isValid = [double]::TryParse(
                    $value,
                    [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsedDouble
                )
            } elseif ($column.dataType -eq "dateTime") {
                $parsedDate = [datetime]::MinValue
                $isValid = [datetime]::TryParseExact(
                    $value,
                    "yyyy-MM-dd",
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$parsedDate
                )
            } elseif ($column.dataType -eq "boolean") {
                $parsedBoolean = $false
                $isValid = [bool]::TryParse($value, [ref]$parsedBoolean)
            }

            if (-not $isValid) {
                throw "Tipo invalido en $tableName.$($column.sourceColumn), fila $($rowIndex + 2): $value"
            }
        }
    }
}

$visualFiles = @(
    [System.IO.Directory]::EnumerateFiles(
        $pagesRoot,
        "visual.json",
        [System.IO.SearchOption]::AllDirectories
    )
)
foreach ($path in $visualFiles) {
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($match in [regex]::Matches($text, '"queryRef"\s*:\s*"([^"]+)"')) {
        $reference = $match.Groups[1].Value
        $separator = $reference.IndexOf(".")
        if ($separator -lt 1) {
            continue
        }
        $entity = $reference.Substring(0, $separator)
        $property = $reference.Substring($separator + 1)
        if (-not $modelTables.ContainsKey($entity)) {
            throw "Visual con tabla inexistente: $reference"
        }
        if (
            -not $modelTables[$entity].Columns.ContainsKey($property) -and
            -not $modelTables[$entity].Measures.ContainsKey($property)
        ) {
            throw "Visual con campo inexistente: $reference"
        }
    }
}

$pageFiles = @(
    [System.IO.Directory]::EnumerateFiles(
        $pagesRoot,
        "page.json",
        [System.IO.SearchOption]::AllDirectories
    )
)
$pageNames = @(
    $pageFiles |
        ForEach-Object {
            ([System.IO.File]::ReadAllText($_) | ConvertFrom-Json).displayName
        }
)
$expectedPages = @(
    "Panorama ejecutivo",
    "Canasta fija",
    "Calidad y cobertura",
    "Drivers y sensibilidad"
)
if (@($expectedPages | Where-Object { $_ -notin $pageNames }).Count -gt 0) {
    throw "No se encontraron las cuatro paginas requeridas."
}
if ($modelTables.Count -ne 14 -or $modelDefinition.model.relationships.Count -ne 9) {
    throw "El modelo no conserva las 14 tablas y 9 relaciones esperadas."
}
if ($pageFiles.Count -ne 4 -or $visualFiles.Count -ne 26) {
    throw "El reporte no conserva las 4 paginas y 26 visuales esperados."
}

$measureCount = 0
foreach ($table in $modelDefinition.model.tables) {
    if ($null -ne $table.measures) {
        $measureCount += @($table.measures).Count
    }
}
if ($measureCount -ne 17) {
    throw "El modelo no conserva las 17 medidas esperadas."
}

Write-Output "Validacion estatica PBIP superada."
Write-Output "JSON: $($jsonFiles.Count) archivos."
Write-Output "Modelo: $($modelTables.Count) tablas, $($modelDefinition.model.relationships.Count) relaciones, $measureCount medidas."
Write-Output "Reporte PBIR: $($pageFiles.Count) paginas, $($visualFiles.Count) visuales."
Write-Output "Filas CSV: $(($requiredSources | ForEach-Object { $_ + '=' + $rowCounts[$_] }) -join '; ')."

if ($SkipTom) {
    Write-Output "Validacion TOM omitida por -SkipTom."
    exit 0
}

if (-not $DesktopBin) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $desktopCommand = Get-Command "PBIDesktop.exe" -ErrorAction SilentlyContinue
    if ($desktopCommand) {
        $candidates.Add((Split-Path -Parent $desktopCommand.Source))
    }
    $candidates.Add((Join-Path $env:ProgramFiles "Microsoft Power BI Desktop\bin"))
    $desktopPackage = Get-AppxPackage -Name "Microsoft.MicrosoftPowerBIDesktop" `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($desktopPackage) {
        $candidates.Add((Join-Path $desktopPackage.InstallLocation "bin"))
    }
    foreach ($candidate in $candidates) {
        if (
            (Test-Path -LiteralPath (Join-Path $candidate "Microsoft.AnalysisServices.Server.Core.dll")) -and
            (Test-Path -LiteralPath (Join-Path $candidate "Microsoft.AnalysisServices.Server.Tabular.dll"))
        ) {
            $DesktopBin = $candidate
            break
        }
    }
}

if (-not $DesktopBin) {
    throw "No se encontro Power BI Desktop para validar model.bim con TOM. Usa -SkipTom para ejecutar solo controles estaticos."
}

Add-Type -Path (Join-Path $DesktopBin "Microsoft.AnalysisServices.Server.Core.dll")
Add-Type -Path (Join-Path $DesktopBin "Microsoft.AnalysisServices.Server.Tabular.dll")
$database = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($modelText)
Write-Output "Validacion TOM superada con Power BI Desktop."
Write-Output "Modelo TOM: $($database.Model.Tables.Count) tablas, $($database.Model.Relationships.Count) relaciones."
