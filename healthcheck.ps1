$Root = $PSScriptRoot
$Config = Get-Content (Join-Path $Root 'config\config.json') -Raw | ConvertFrom-Json
try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($Config.port)/health" -TimeoutSec 3
    $health | ConvertTo-Json
} catch {
    Write-Host '服务未运行或尚未就绪。' -ForegroundColor Yellow
    exit 1
}
