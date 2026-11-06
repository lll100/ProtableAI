param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$path = Join-Path $Root 'config\config.json'
$config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$value = $config.$Name
if ($null -ne $value) {
    [Console]::WriteLine([string]$value)
}
