param([switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$StartupLog = Join-Path $LogDir 'startup.log'
$StdoutLog = Join-Path $LogDir 'server.log'
$StderrLog = Join-Path $LogDir 'server-error.log'
$ServiceErrorLog = Join-Path $LogDir 'service_error.log'
$PidFile = Join-Path $LogDir 'server.pid'
Set-Content -LiteralPath $StartupLog -Value '' -Encoding UTF8
Set-Content -LiteralPath $StdoutLog -Value '' -Encoding UTF8
Set-Content -LiteralPath $StderrLog -Value '' -Encoding UTF8
Set-Content -LiteralPath $ServiceErrorLog -Value '' -Encoding UTF8

function Write-Stage {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $StartupLog -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor $Color
}
function Show-ServerTail {
    param([string]$LogPath = $StderrLog)
    if (Test-Path -LiteralPath $LogPath) {
        $last = Get-Content -LiteralPath $LogPath -Tail 3 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 1
        if ($last) { Write-Stage ("server: " + $last.Trim()) 'DarkGray' }
    }
}
function Copy-ErrorEvidence {
    param([string]$Backend, [string]$AttemptLog, [string]$AttemptStdout = '', [int]$ExitCode = -1)
    $header = "`r`n===== backend=$Backend exit_code=$ExitCode time=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
    Add-Content -LiteralPath $ServiceErrorLog -Value $header -Encoding UTF8
    if (Test-Path -LiteralPath $AttemptLog) {
        $content = Get-Content -LiteralPath $AttemptLog -Raw -ErrorAction SilentlyContinue
        if ($content) { Add-Content -LiteralPath $ServiceErrorLog -Value $content -Encoding UTF8 }
    }
    if ($AttemptStdout -and (Test-Path -LiteralPath $AttemptStdout)) {
        $content = Get-Content -LiteralPath $AttemptStdout -Raw -ErrorAction SilentlyContinue
        if ($content) {
            Add-Content -LiteralPath $ServiceErrorLog -Value "----- stdout -----" -Encoding UTF8
            Add-Content -LiteralPath $ServiceErrorLog -Value $content -Encoding UTF8
        }
    }
    Copy-Item -LiteralPath $ServiceErrorLog -Destination $StderrLog -Force -ErrorAction SilentlyContinue
}
function Explain-ExitCode {
    param([int]$ExitCode)
    switch ($ExitCode) {
        -1073741515 { return 'Windows 错误 0xC0000135：缺少 DLL，优先检查 VC++/UCRT 运行库' }
        -1073741701 { return 'Windows 错误 0xC000007B：DLL 位数或运行库不匹配' }
        -1073740940 { return 'Windows 错误 0xC0000014：映像格式无效，检查运行时文件是否损坏' }
        default { return '' }
    }
}
function Ensure-HelperProcess {
    param([string]$Name, [string]$ScriptPath, [int]$HelperPort, [string]$PidPath, [string]$LogPath, [int]$LlamaPort = 0)
    $listening = @()
    try { $listening = @(Get-NetTCPConnection -LocalPort $HelperPort -State Listen -ErrorAction SilentlyContinue) } catch { }
    if ($listening.Count -gt 0) { Write-Stage ("[辅助服务] " + $Name + ' 已在端口 ' + $HelperPort + ' 监听') 'DarkGray'; return }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { Write-Stage ("[辅助服务] 找不到 " + $ScriptPath) 'Yellow'; return }
    try {
        $ps = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $ps) { $ps = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source }
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Port',"$HelperPort",'-Root',$Root)
        if ($LlamaPort -gt 0) { $args += @('-LlamaPort',"$LlamaPort") }
        $proc = Start-Process -FilePath $ps -ArgumentList $args -WorkingDirectory $Root -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath + '.err') -WindowStyle Hidden -PassThru
        Set-Content -LiteralPath $PidPath -Value $proc.Id -Encoding ASCII
        Write-Stage ("[辅助服务] " + $Name + ' 已启动：PID=' + $proc.Id + ', 端口=' + $HelperPort) 'Green'
    } catch { Write-Stage ("[辅助服务] " + $Name + ' 启动失败：' + $_.Exception.Message) 'Yellow' }
}
function Get-ProcessPathSafe {
    param([int]$Id)
    try { return [string](Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction Stop).ExecutablePath } catch { return '' }
}

Write-Stage '[1/8] PortableAI 启动开始' 'Cyan'
Write-Stage ("工作目录：" + $Root)
try {
    $ConfigPath = Join-Path $Root 'config\config.json'
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    Write-Stage ("[2/8] 配置读取成功：模型=" + $Config.model + ", 端口=" + $Config.port) 'Green'
} catch {
    Write-Stage ("配置读取失败：" + $_.Exception.Message) 'Red'
    exit 10
}

$controlPort = 11434
if ($Config.control_port) { $controlPort = [int]$Config.control_port }
$anthropicPort = 11436
if ($Config.anthropic_port) { $anthropicPort = [int]$Config.anthropic_port }
Ensure-HelperProcess -Name '控制台' -ScriptPath (Join-Path $Root 'tools\control-server.ps1') -HelperPort $controlPort -PidPath (Join-Path $LogDir 'control.pid') -LogPath (Join-Path $LogDir 'control-launcher.log')
Ensure-HelperProcess -Name 'Claude/Codex API 适配器' -ScriptPath (Join-Path $Root 'tools\anthropic-gateway.ps1') -HelperPort $anthropicPort -LlamaPort ([int]$Config.port) -PidPath (Join-Path $LogDir 'anthropic-gateway.pid') -LogPath (Join-Path $LogDir 'gateway-launcher.log')

$ModelPath = Join-Path (Join-Path $Root 'models') $Config.model
if (-not (Test-Path -LiteralPath $ModelPath)) {
    Write-Stage ("模型不存在：" + $ModelPath) 'Red'
    exit 11
}
$modelSize = [math]::Round((Get-Item -LiteralPath $ModelPath).Length / 1GB, 2)
Write-Stage ("[3/8] 模型文件存在：" + $modelSize + ' GB') 'Green'

$port = [int]$Config.port
$ctx = [int]$Config.context
$maxTokens = [int]$Config.max_tokens
$temperature = 0.8
if ($null -ne $Config.temperature) { $temperature = [double]$Config.temperature }
$timeout = 180
if ($Config.startup_timeout_sec) { $timeout = [int]$Config.startup_timeout_sec }
$ram = 0
$logical = 4
try { $ram = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1) } catch { Write-Stage '无法读取系统内存，继续使用默认值' 'Yellow' }
try { $logical = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum } catch { Write-Stage '无法读取 CPU 线程数，使用 4 线程' 'Yellow' }
$threads = [int]$Config.threads
if ($threads -le 0) { $threads = [Math]::Max(2, [Math]::Min(8, [int]$logical)) }
$batchSize = 512
$ubatchSize = 256
if ($ram -gt 0 -and $ram -le 6) {
    $ctx = [Math]::Min($ctx, 4096)
    $batchSize = 128
    $ubatchSize = 64
    $threads = [Math]::Min($threads, [Math]::Max(2, [Math]::Min(4, [int]$logical)))
    Write-Stage ("[4/8] 低内存模式：自动调整 context=" + $ctx + ', batch=' + $batchSize + ', ubatch=' + $ubatchSize) 'Yellow'
} elseif ($ram -gt 0 -and $ram -le 8) {
    $ctx = [Math]::Min($ctx, 4096)
    $batchSize = 256
    $ubatchSize = 128
    Write-Stage ("[4/8] 受限内存模式：自动调整 context=" + $ctx + ', batch=' + $batchSize + ', ubatch=' + $ubatchSize) 'Yellow'
}
Write-Stage ("[4/8] 主机信息：RAM=" + $ram + ' GB, 逻辑线程=' + $logical + ', 使用线程=' + $threads + ', context=' + $ctx)

$runtimeRoot = Join-Path $Root 'runtime'
$hasNvidia = $false
$hasVulkanGpu = $false
try {
    $videoNames = @(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name)
    $hasNvidia = @($videoNames | Where-Object { $_ -match 'NVIDIA' }).Count -gt 0
    $hasVulkanGpu = @($videoNames | Where-Object { $_ -match 'NVIDIA|AMD|Radeon|Intel' }).Count -gt 0
    Write-Stage ("显卡检测：" + (($videoNames | Where-Object { $_ }) -join '; '))
} catch { Write-Stage '显卡检测失败，按 CPU 处理' 'Yellow' }

$backends = New-Object System.Collections.Generic.List[string]
$requestedBackend = [string]$Config.backend
if (-not $requestedBackend) { $requestedBackend = 'auto' }
if ($requestedBackend -eq 'cuda') {
    if ($hasNvidia -and (Test-Path (Join-Path $runtimeRoot 'cuda\llama-server.exe')) -and @(Get-ChildItem (Join-Path $runtimeRoot 'cuda') -Filter 'cudart64_*.dll' -ErrorAction SilentlyContinue).Count -gt 0) { [void]$backends.Add('cuda') } else { Write-Stage '已指定 CUDA，但当前环境未检测到可用 CUDA 运行时' 'Yellow' }
} elseif ($requestedBackend -eq 'vulkan') {
    if ($hasVulkanGpu -and (Test-Path (Join-Path $runtimeRoot 'vulkan\llama-server.exe'))) { [void]$backends.Add('vulkan') } else { Write-Stage '已指定 Vulkan，但当前环境未检测到可用 Vulkan 运行时' 'Yellow' }
} elseif ($requestedBackend -eq 'cpu') {
    if (Test-Path (Join-Path $runtimeRoot 'cpu\llama-server.exe')) { [void]$backends.Add('cpu') } else { Write-Stage '已指定 CPU，但 CPU 运行时文件不存在' 'Yellow' }
} else {
    if ([bool]$Config.prefer_gpu -and $hasNvidia -and (Test-Path (Join-Path $runtimeRoot 'cuda\llama-server.exe')) -and @(Get-ChildItem (Join-Path $runtimeRoot 'cuda') -Filter 'cudart64_*.dll' -ErrorAction SilentlyContinue).Count -gt 0) { [void]$backends.Add('cuda') }
    if ([bool]$Config.prefer_gpu -and $hasVulkanGpu -and (Test-Path (Join-Path $runtimeRoot 'vulkan\llama-server.exe'))) { [void]$backends.Add('vulkan') }
}
if ([bool]$Config.auto_cpu_fallback -or $backends.Count -eq 0) {
    if (Test-Path (Join-Path $runtimeRoot 'cpu\llama-server.exe')) { [void]$backends.Add('cpu') }
}
Write-Stage ("[5/8] 后端选择：请求=" + $requestedBackend + '，候选=' + (($backends | Select-Object -Unique) -join ' -> ')) 'Cyan'

$requiredDlls = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
foreach ($backend in ($backends | Select-Object -Unique)) {
    $backendDir = Join-Path $runtimeRoot $backend
    $missing = @($requiredDlls | Where-Object { -not (Test-Path -LiteralPath (Join-Path $backendDir $_)) })
    if ($missing.Count -gt 0) {
        Write-Stage ("运行时依赖提示：" + $backend + ' 目录缺少 ' + ($missing -join ', ') + '；请将 VC++ 运行库 DLL 放入该目录') 'Yellow'
        Add-Content -LiteralPath $ServiceErrorLog -Value ("backend=$backend missing_dll=" + ($missing -join ',')) -Encoding UTF8
    }
}

if (Test-Path -LiteralPath $PidFile) {
    $oldPidText = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $oldPid = 0
    if ([int]::TryParse([string]$oldPidText, [ref]$oldPid)) {
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc) {
            $existingStatus = ''
            try {
                $existingHealth = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $port + '/health') -TimeoutSec 3
                $existingStatus = [string]$existingHealth.status
            } catch { }
            if ($existingStatus -eq 'ok') {
                Write-Stage ("服务已经运行：PID=" + $oldPid + ', 地址=http://127.0.0.1:' + $port) 'Green'
                Start-Process ("http://127.0.0.1:" + $port)
                exit 0
            }
            if ($existingStatus -eq 'loading model') {
                Write-Stage ("发现已有进程正在加载模型：PID=" + $oldPid + '，继续等待，不重复启动') 'Yellow'
                for ($existingSecond = 1; $existingSecond -le $timeout; $existingSecond++) {
                    Start-Sleep -Seconds 1
                    if (-not (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) { break }
                    try {
                        $existingHealth = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $port + '/health') -TimeoutSec 2
                        if ($existingHealth.status -eq 'ok') {
                            Write-Stage ("已有进程加载完成：" + $existingSecond + '/' + $timeout + ' 秒') 'Green'
                            Start-Process ("http://127.0.0.1:" + $port)
                            exit 0
                        }
                    } catch { }
                    if (($existingSecond -eq 1) -or (($existingSecond % 5) -eq 0)) {
                        Write-Stage ("已有进程加载中：" + $existingSecond + '/' + $timeout + ' 秒') 'DarkGray'
                        Show-ServerTail
                    }
                }
                Write-Stage '已有进程超时或失去响应，准备清理后重新启动' 'Yellow'
            } else {
                Write-Stage ("发现无响应的旧进程 PID=" + $oldPid + '，准备清理后重新启动') 'Yellow'
            }
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Stage '旧 PID 文件已清理' 'Yellow'
}
try {
    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $owners = ($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
        Write-Stage ("端口 " + $port + ' 已被进程占用：' + $owners) 'Red'
        exit 12
    }
} catch { Write-Stage '无法检查端口占用，继续启动' 'Yellow' }

$startedBackend = $null
$startedProc = $null
foreach ($backend in ($backends | Select-Object -Unique)) {
    $exe = Join-Path $runtimeRoot ($backend + '\llama-server.exe')
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Stage ("跳过 " + $backend + '：找不到 ' + $exe) 'Yellow'
        continue
    }
    $gpuLayers = 0
    if ($backend -ne 'cpu') { $gpuLayers = [int]$Config.gpu_layers }
    $args = @('--model', $ModelPath, '--host', '127.0.0.1', '--port', "$port", '--ctx-size', "$ctx", '--n-predict', "$maxTokens", '--temperature', "$temperature", '--threads', "$threads", '--threads-batch', "$threads", '--batch-size', "$batchSize", '--ubatch-size', "$ubatchSize", '--parallel', '1', '--n-gpu-layers', "$gpuLayers", '--reasoning', "$($Config.reasoning)")
    if ($Config.metrics -ne $false) { $args += '--metrics' }
    $attemptStdout = Join-Path $LogDir ("server-" + $backend + '.log')
    $attemptStderr = Join-Path $LogDir ("server-" + $backend + '-error.log')
    Set-Content -LiteralPath $attemptStdout -Value '' -Encoding UTF8
    Set-Content -LiteralPath $attemptStderr -Value '' -Encoding UTF8
    Write-Stage ("[6/8] 尝试启动后端：" + $backend + ', 可执行文件=' + $exe) 'Cyan'
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Split-Path -Parent $exe) -RedirectStandardOutput $attemptStdout -RedirectStandardError $attemptStderr -WindowStyle Hidden -PassThru
        Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
        Write-Stage ("进程已创建：PID=" + $proc.Id)
    } catch {
        Write-Stage ("进程创建失败：" + $_.Exception.Message) 'Red'
        continue
    }
    $ready = $false
    for ($second = 1; $second -le $timeout; $second++) {
        Start-Sleep -Seconds 1
        $running = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $running) {
            $exitCode = -1
            try { $proc.Refresh(); if ($proc.HasExited) { $exitCode = $proc.ExitCode } } catch { }
            Copy-ErrorEvidence -Backend $backend -AttemptLog $attemptStderr -AttemptStdout $attemptStdout -ExitCode $exitCode
            Write-Stage ("后端 " + $backend + ' 在第 ' + $second + ' 秒退出，退出码=' + $exitCode + '，准备回退') 'Yellow'
            $explanation = Explain-ExitCode -ExitCode $exitCode
            if ($explanation) { Write-Stage $explanation 'Red'; Add-Content -LiteralPath $ServiceErrorLog -Value $explanation -Encoding UTF8 }
            Show-ServerTail -LogPath $attemptStderr
            break
        }
        try {
            $health = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $port + '/health') -TimeoutSec 2
            if ($health.status -eq 'ok') {
                $ready = $true
                break
            }
        } catch { }
        if (($second -eq 1) -or (($second % 5) -eq 0)) {
            Write-Stage ("等待模型加载：" + $second + '/' + $timeout + ' 秒') 'DarkGray'
            Show-ServerTail -LogPath $attemptStderr
        }
    }
    if ($ready) {
        $startedBackend = $backend
        $startedProc = $proc
        break
    }
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
        Write-Stage ("停止未就绪的 " + $backend + ' 进程，尝试下一个后端') 'Yellow'
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Copy-ErrorEvidence -Backend $backend -AttemptLog $attemptStderr -AttemptStdout $attemptStdout -ExitCode -1
}

if (-not $startedBackend) {
    if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }
    Write-Stage '[7/8] 所有后端都未能启动' 'Red'
    Write-Stage ("请查看：" + $ServiceErrorLog) 'Red'
    if (Test-Path -LiteralPath $ServiceErrorLog) {
        Write-Host '----- service_error.log 最近 50 行 -----' -ForegroundColor Yellow
        Get-Content -LiteralPath $ServiceErrorLog -Tail 50
        Write-Host '----------------------------------------' -ForegroundColor Yellow
    }
    exit 20
}

Write-Stage ("[7/8] 服务就绪：backend=" + $startedBackend + ', PID=' + $startedProc.Id) 'Green'
Write-Stage ("[8/8] 地址：http://127.0.0.1:" + $port) 'Green'
Write-Stage ("控制台：http://127.0.0.1:" + $controlPort + '；Claude/Codex 适配器：http://127.0.0.1:' + $anthropicPort) 'Green'
if (-not $NoBrowser) { Start-Process ("http://127.0.0.1:" + $controlPort) }
exit 0
