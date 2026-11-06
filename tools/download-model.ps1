$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$modelPath = Join-Path $Root 'models\Qwen3-4B-Q4_K_M.gguf'
if (Test-Path -LiteralPath $modelPath) {
    Write-Host "模型已存在：$modelPath" -ForegroundColor Green
    exit 0
}
$urls = @(
    'https://modelscope.cn/models/Qwen/Qwen3-4B-GGUF/resolve/master/Qwen3-4B-Q4_K_M.gguf',
    'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true'
)
foreach ($url in $urls) {
    if (Test-Path -LiteralPath $modelPath) { Remove-Item -LiteralPath $modelPath -Force }
    Write-Host "正在下载官方 Qwen3-4B Q4_K_M（约 2.5 GB）：$url" -ForegroundColor Cyan
    & curl.exe -L --fail --retry 3 --retry-delay 5 --progress-bar --output "$modelPath" "$url"
    if ($LASTEXITCODE -eq 0 -and (Test-Path $modelPath) -and (Get-Item $modelPath).Length -gt 2000000000) { break }
    Write-Host '当前镜像下载失败，尝试下一个官方镜像。' -ForegroundColor Yellow
    if (Test-Path -LiteralPath $modelPath) { Remove-Item -LiteralPath $modelPath -Force }
}
if (-not (Test-Path -LiteralPath $modelPath)) { throw '模型下载失败' }
$hash = Get-FileHash -LiteralPath $modelPath -Algorithm SHA256
$hash | Out-File -LiteralPath (Join-Path $Root 'models\Qwen3-4B-Q4_K_M.sha256.txt') -Encoding ASCII
Write-Host "SHA256: $($hash.Hash)" -ForegroundColor DarkGray
Write-Host '模型下载完成。' -ForegroundColor Green
