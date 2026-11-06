$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root 'config\config.json'
$PidFile = Join-Path $Root 'logs\server.pid'
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$port = [int]$Config.port
$targetPids = New-Object System.Collections.Generic.HashSet[int]

if (Test-Path -LiteralPath $PidFile) {
    $pidText = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $pidNumber = 0
    if ([int]::TryParse([string]$pidText, [ref]$pidNumber) -and $pidNumber -gt 0) {
        [void]$targetPids.Add($pidNumber)
    }
}

$connections = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
foreach ($connection in $connections) { [void]$targetPids.Add([int]$connection.OwningProcess) }

$stopped = @()
$skipped = @()
foreach ($targetPid in $targetPids) {
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    $info = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
    $path = [string]$info.ExecutablePath
    $isPortable = ($path -like (Join-Path $Root 'runtime\*')) -or ($proc.ProcessName -eq 'llama-server' -and $targetPid -eq $pidNumber)
    if ($isPortable) {
        Stop-Process -Id $targetPid -Force -ErrorAction Stop
        $stopped += $targetPid
    } else {
        $skipped += $targetPid
    }
}
Start-Sleep -Milliseconds 500
$remaining = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
if ($remaining.Count -gt 0) {
    $owners = ($remaining | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
    throw "停止失败：端口 $port 仍被进程 $owners 占用。"
}
if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction Stop }
if ($stopped.Count -gt 0) {
    Write-Host ("PortableAI 已停止，PID: " + (($stopped | Sort-Object -Unique) -join ', ')) -ForegroundColor Green
} else {
    Write-Host 'PortableAI 当前没有运行；已清理旧 PID 文件。' -ForegroundColor Yellow
}
if ($skipped.Count -gt 0) { Write-Host ("未处理非 PortableAI 进程: " + (($skipped | Sort-Object -Unique) -join ', ')) -ForegroundColor Yellow }
Write-Host '浏览器页面不会自动关闭；关闭页面不会影响服务状态。' -ForegroundColor DarkGray
