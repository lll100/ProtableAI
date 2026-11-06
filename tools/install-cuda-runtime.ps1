$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$downloadDir = Join-Path $Root 'logs\downloads'
$dest = Join-Path $Root 'runtime\cuda'
New-Item -ItemType Directory -Force -Path $downloadDir,$dest | Out-Null
$headers = @{ 'User-Agent' = 'PortableAI-Setup' }
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10' -Headers $headers
$release = $releases | Where-Object { @($_.assets | Where-Object { $_.name -match 'cudart-llama-bin-win-cuda-12\.4-x64\.zip' }).Count -gt 0 } | Select-Object -First 1
if (-not $release) { throw '找不到 CUDA 运行库 release' }
$asset = $release.assets | Where-Object { $_.name -eq 'cudart-llama-bin-win-cuda-12.4-x64.zip' } | Select-Object -First 1
$archive = Join-Path $downloadDir $asset.name
if (-not (Test-Path $archive) -or (Get-Item $archive).Length -ne [int64]$asset.size) {
    Write-Host "下载 CUDA 运行库（约 373 MB）" -ForegroundColor Cyan
    & curl.exe -L --fail --retry 3 --retry-delay 5 --progress-bar --output "$archive" "$($asset.browser_download_url)"
    if ($LASTEXITCODE -ne 0) { throw 'CUDA 运行库下载失败' }
}
$temp = Join-Path $downloadDir ('extract-cudart-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
Expand-Archive -LiteralPath $archive -DestinationPath $temp -Force
Get-ChildItem -LiteralPath $temp -File -Recurse | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dest -Force }
cmd.exe /c "where cudart64_12.dll" 2>$null
Write-Host 'CUDA 运行库已补充。重新运行 start.bat 即可自动选择 CUDA。' -ForegroundColor Green
