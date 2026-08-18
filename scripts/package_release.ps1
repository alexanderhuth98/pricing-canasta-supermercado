$ErrorActionPreference = "Stop"

$version = "v2.0.0"
$projectRoot = (Get-Location).Path
$destination = Join-Path $projectRoot "outputs\release-$version"
$assets = @(
    "powerbi\PricingCanasta.pbix",
    "outputs\pricing_canasta_supermercado.xlsx",
    "outputs\dashboard_pricing_canasta.html",
    "outputs\dashboard_mobile.html"
)

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot "pyproject.toml"))) {
    throw "Ejecute este script desde la raiz del repositorio."
}

New-Item -ItemType Directory -Path $destination -Force | Out-Null
$checksums = @()

foreach ($relativePath in $assets) {
    $source = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Falta el activo requerido: $relativePath"
    }

    $target = Join-Path $destination (Split-Path $source -Leaf)
    Copy-Item -LiteralPath $source -Destination $target -Force
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums += "$hash *$(Split-Path $target -Leaf)"
}

$checksumPath = Join-Path $destination "SHA256SUMS.txt"
$checksums | Out-File -LiteralPath $checksumPath -Encoding ascii

Write-Output "Release preparado en $destination"
$checksums | Write-Output
