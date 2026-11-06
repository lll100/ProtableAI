$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'config\config.json'
Write-Host '=== PortableAI Diagnose ===' -ForegroundColor Cyan
Write-Host "Root: $Root"
try { $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json; Write-Host "Config: OK (model=$($Config.model), port=$($Config.port))" -ForegroundColor Green } catch { Write-Host "Config: FAIL - $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$model = Join-Path (Join-Path $Root 'models') $Config.model
if (Test-Path $model) { $size=(Get-Item $model).Length/1GB; Write-Host ("Model: OK ({0:N2} GB)" -f $size) -ForegroundColor Green } else { Write-Host "Model: FAIL - $model" -ForegroundColor Red }
foreach($name in @('cpu','vulkan','cuda')) { $exe=Join-Path $Root "runtime\$name\llama-server.exe"; if(Test-Path $exe){Write-Host "Runtime $name`: OK" -ForegroundColor Green}else{Write-Host "Runtime $name`: missing" -ForegroundColor Yellow} }
$requiredDlls=@('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','ucrtbase.dll'); foreach($name in @('cpu','vulkan','cuda')) { $dir=Join-Path $Root "runtime\$name"; if(Test-Path (Join-Path $dir 'llama-server.exe')) { $missing=@($requiredDlls | Where-Object { -not (Test-Path (Join-Path $dir $_)) }); if($missing.Count -eq 0){Write-Host "Runtime $name DLLs: OK" -ForegroundColor Green}else{Write-Host ("Runtime $name DLLs: missing " + ($missing -join ', ')) -ForegroundColor Red} } }
$gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Virtual|Todesk|Todesk|Oray' } | Select-Object -ExpandProperty Name
if($gpu){ Write-Host ('GPU: ' + ($gpu -join '; ')) } else { Write-Host 'GPU: not detected' -ForegroundColor Yellow }
$pidFile=Join-Path $Root 'logs\server.pid'
if(Test-Path $pidFile){$pidValue=Get-Content $pidFile -ErrorAction SilentlyContinue; $proc=Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue; if($proc){$info=Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue; Write-Host "Process: OK (PID=$pidValue, RAM=$([math]::Round($proc.WorkingSet64/1MB)) MB)" -ForegroundColor Green; if($info){Write-Host "Executable: $($info.ExecutablePath)"}}else{Write-Host 'Process: stopped' -ForegroundColor Yellow}}else{Write-Host 'Process: no PID file' -ForegroundColor Yellow}
try{$h=Invoke-RestMethod "http://127.0.0.1:$($Config.port)/health" -TimeoutSec 3; Write-Host "HTTP: OK ($($h.status))" -ForegroundColor Green}catch{Write-Host "HTTP: FAIL - $($_.Exception.Message)" -ForegroundColor Red}
$controlPort=11434; if($Config.control_port){$controlPort=[int]$Config.control_port}; $gatewayPort=11436; if($Config.anthropic_port){$gatewayPort=[int]$Config.anthropic_port}
try{$c=Invoke-RestMethod "http://127.0.0.1:$controlPort/api/ping" -TimeoutSec 3; Write-Host "Control room: OK (port=$controlPort)" -ForegroundColor Green}catch{Write-Host "Control room: FAIL - $($_.Exception.Message)" -ForegroundColor Yellow}
try{$g=Invoke-RestMethod "http://127.0.0.1:$gatewayPort/health" -TimeoutSec 3; Write-Host "Agent gateway: OK (port=$gatewayPort)" -ForegroundColor Green}catch{Write-Host "Agent gateway: FAIL - $($_.Exception.Message)" -ForegroundColor Yellow}
Write-Host '--- startup progress ---' -ForegroundColor Cyan
$startup=Join-Path $Root 'logs\\startup.log'; if(Test-Path $startup){Get-Content $startup -Tail 20}else{Write-Host 'No startup.log'}
Write-Host '--- recent server errors ---' -ForegroundColor Cyan
$log=Join-Path $Root 'logs\server-error.log'; if(Test-Path $log){Get-Content $log -Tail 12}else{Write-Host 'No server-error.log'}
Write-Host '--- service_error.log ---' -ForegroundColor Cyan
$serviceLog=Join-Path $Root 'logs\service_error.log'; if(Test-Path $serviceLog){Get-Content $serviceLog -Tail 20}else{Write-Host 'No service_error.log'}
