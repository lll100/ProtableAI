$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
& (Join-Path $Root 'stop.ps1')
$helperFiles = @('logs\control.pid','logs\anthropic-gateway.pid')
foreach ($relative in $helperFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $helperPid = 0
    [int]::TryParse([string](Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$helperPid) | Out-Null
    if ($helperPid -le 0) { continue }
    $info = Get-CimInstance Win32_Process -Filter "ProcessId=$helperPid" -ErrorAction SilentlyContinue
    if ($info -and ([string]$info.CommandLine -match 'control-server\.ps1|anthropic-gateway\.ps1')) { Stop-Process -Id $helperPid -Force -ErrorAction SilentlyContinue; Write-Host ("已停止辅助服务 PID=" + $helperPid) -ForegroundColor Green }
}
Write-Host 'PortableAI 全部本地服务已停止。' -ForegroundColor Green
