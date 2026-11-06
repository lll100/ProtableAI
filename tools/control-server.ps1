param(
    [int]$Port = 11434,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $Root 'config\config.json'
$ProvidersPath = Join-Path $Root 'config\providers.json'
$LogDir = Join-Path $Root 'logs'
$LogPath = Join-Path $LogDir 'control.log'
$PidPath = Join-Path $LogDir 'control.pid'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}
function Get-Config { Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
}
function Send-Text {
    param($Context, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
    Send-Bytes -Context $Context -Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType -Status $Status
}
function Send-Json {
    param($Context, $Value, [int]$Status = 200)
    Send-Text -Context $Context -Text ($Value | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8' -Status $Status
}
function Read-Body {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Get-QueryValue {
    param($Context, [string]$Name, [string]$Default = '')
    $value = $Context.Request.QueryString[$Name]
    if ($null -eq $value -or $value -eq '') { return $Default }
    return $value
}
function Get-ModelHealth {
    param([int]$LlamaPort)
    try { return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $LlamaPort) -TimeoutSec 2 } catch { return [pscustomobject]@{ status = 'offline'; detail = $_.Exception.Message } }
}
function Get-ProcessSnapshot {
    $pidPath = Join-Path $LogDir 'server.pid'
    $serverPid = 0
    if (Test-Path -LiteralPath $pidPath) { [int]::TryParse([string](Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$serverPid) | Out-Null }
    $proc = if ($serverPid -gt 0) { Get-Process -Id $serverPid -ErrorAction SilentlyContinue } else { $null }
    if (-not $proc) { return [pscustomobject]@{ running = $false; pid = $null; memory_mb = $null; uptime_sec = $null } }
    $uptime = 0
    try { $uptime = [math]::Round(((Get-Date) - $proc.StartTime).TotalSeconds) } catch { }
    return [pscustomobject]@{ running = $true; pid = $serverPid; memory_mb = [math]::Round($proc.WorkingSet64 / 1MB); uptime_sec = $uptime }
}
function Get-BackendName {
    $startup = Join-Path $LogDir 'startup.log'
    if (Test-Path -LiteralPath $startup) {
        $match = Get-Content -LiteralPath $startup -ErrorAction SilentlyContinue | Select-String -Pattern '服务就绪：backend=([^,]+)' | Select-Object -Last 1
        if ($match -and $match.Matches.Count -gt 0) { return $match.Matches[0].Groups[1].Value }
    }
    $pidPath = Join-Path $LogDir 'server.pid'
    if (Test-Path -LiteralPath $pidPath) {
        $serverPid = 0
        [int]::TryParse([string](Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$serverPid) | Out-Null
        if ($serverPid -gt 0) {
            try {
                $path = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$serverPid" -ErrorAction Stop).ExecutablePath
                $m = [regex]::Match($path, 'runtime[\\/](cpu|vulkan|cuda)[\\/]llama-server\.exe', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
            } catch { }
        }
    }
    return ''
}
function Get-MetricsText {
    param([int]$LlamaPort)
    try { return (Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/metrics" -f $LlamaPort) -UseBasicParsing -TimeoutSec 2).Content } catch { return '' }
}
function Get-SystemSnapshot {
    $memoryTotal = 0; $memoryFree = 0; $cpuLoad = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $memoryTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $memoryFree = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    } catch { }
    try { $cpuLoad = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1) } catch { }
    $used = if($memoryTotal -gt 0){[math]::Round((1-($memoryFree/$memoryTotal))*100,1)}else{$null}
    return [ordered]@{ cpu_percent=$cpuLoad; memory_total_gb=$memoryTotal; memory_free_gb=$memoryFree; memory_used_percent=$used }
}
function Get-EnvironmentSnapshot {
    $runtimes = @()
    foreach($backend in @('cpu','vulkan','cuda')) {
        $dir = Join-Path $Root ("runtime\{0}" -f $backend)
        $exe = Join-Path $dir 'llama-server.exe'
        $available = Test-Path -LiteralPath $exe
        $detail = if($available){'运行时文件存在'}else{'找不到 llama-server.exe'}
        if($backend -eq 'cuda' -and $available -and @(Get-ChildItem -LiteralPath $dir -Filter 'cudart64_*.dll' -ErrorAction SilentlyContinue).Count -eq 0){$available=$false; $detail='缺少 cudart64_*.dll'}
        $runtimes += [ordered]@{ name=$backend; available=$available; path=$exe; detail=$detail }
    }
    $models = @()
    $modelDir = Join-Path $Root 'models'
    if (Test-Path -LiteralPath $modelDir) {
        foreach($file in @(Get-ChildItem -LiteralPath $modelDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue)) {
            $models += [ordered]@{ name=$file.Name; size_gb=[math]::Round($file.Length/1GB,2); path=$file.FullName }
        }
    }
    $gpus = @()
    try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {$_.Name -notmatch 'Virtual|Todesk|Oray'} | Select-Object -ExpandProperty Name) } catch { }
    $system = Get-SystemSnapshot
    $cudaReady = @($runtimes | Where-Object {$_.name -eq 'cuda' -and $_.available}).Count -gt 0
    $vulkanReady = @($runtimes | Where-Object {$_.name -eq 'vulkan' -and $_.available}).Count -gt 0
    $recommended = if($cudaReady -and (($gpus -join ';') -match 'NVIDIA')){'cuda'}elseif($vulkanReady){'vulkan'}else{'cpu'}
    return [ordered]@{ os=[Environment]::OSVersion.VersionString; computer=$env:COMPUTERNAME; logical_processors=[Environment]::ProcessorCount; gpus=$gpus; system=$system; runtimes=$runtimes; models=$models; recommended_backend=$recommended; root=$Root }
}
function Get-Providers {
    if (-not (Test-Path -LiteralPath $ProvidersPath)) { return [ordered]@{ active_provider=''; providers=@() } }
    return Get-Content -LiteralPath $ProvidersPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Save-Providers {
    param($Incoming)
    if ($null -eq $Incoming.providers) { throw '供应商列表不能为空' }
    $ids = @()
    foreach($provider in @($Incoming.providers)) {
        if (-not $provider.id -or $provider.id -notmatch '^[a-zA-Z0-9._-]+$') { throw '供应商 ID 只能包含字母、数字、点、下划线和短横线' }
        if ($ids -contains [string]$provider.id) { throw "供应商 ID 重复：$($provider.id)" }
        $ids += [string]$provider.id
        if (-not $provider.name) { throw "供应商 $($provider.id) 缺少名称" }
        if (-not $provider.base_url -or $provider.base_url -notmatch '^https?://') { throw "供应商 $($provider.id) 的请求网址必须以 http:// 或 https:// 开头" }
    }
    $active = [string]$Incoming.active_provider
    if ($active -and $ids -notcontains $active) { throw "当前供应商不存在：$active" }
    $data = [ordered]@{ active_provider=$active; providers=@($Incoming.providers) }
    Copy-Item -LiteralPath $ProvidersPath -Destination ($ProvidersPath + '.bak') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $ProvidersPath -Value ($data | ConvertTo-Json -Depth 12) -Encoding UTF8
    $local = @($Incoming.providers | Where-Object {$_.id -eq 'local-portableai'} | Select-Object -First 1)
    if($local -and $local.api_key) {
        $cfg = Get-Config; $cfg.agent_api_key = [string]$local.api_key
        Set-Content -LiteralPath $ConfigPath -Value ($cfg | ConvertTo-Json -Depth 12) -Encoding UTF8
    }
    return Get-Providers
}
function Get-ProviderById {
    param([string]$Id)
    $data = Get-Providers
    $provider = @($data.providers | Where-Object {$_.id -eq $Id} | Select-Object -First 1)
    if(-not $provider){ throw "供应商不存在：$Id" }
    return $provider
}
function Invoke-ProviderProbe {
    param($Request)
    $provider = Get-ProviderById ([string]$Request.provider_id)
    $base = ([string]$provider.base_url).TrimEnd('/')
    $key = [string]$provider.api_key
    $uri = if($base -match '/v1$'){ "$base/models" }else{ "$base/v1/models" }
    $headers = @{}
    if($key){ $headers['Authorization'] = "Bearer $key"; $headers['x-api-key'] = $key }
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -UseBasicParsing -TimeoutSec 8
        $json = $response.Content | ConvertFrom-Json
        $models = @($json.data | ForEach-Object {[string]$_.id} | Where-Object {$_})
        return [ordered]@{ ok=$true; provider_id=$provider.id; status_code=[int]$response.StatusCode; message='连接成功'; models=$models; checked_url=$uri }
    } catch {
        return [ordered]@{ ok=$false; provider_id=$provider.id; status_code=0; message=$_.Exception.Message; models=@(); checked_url=$uri }
    }
}
function Get-ProviderFile {
    param([string]$Id)
    $provider = Get-ProviderById $Id
    $relative = [string]$provider.config_file
    if (-not $relative) { throw "供应商未配置 config_file：$Id" }
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw '配置文件路径超出 PortableAI 根目录' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "配置文件不存在：$relative" }
    $content = [IO.File]::ReadAllText($candidate, [Text.Encoding]::UTF8)
    return [ordered]@{ provider_id=$provider.id; path=$relative; content=$content }
}
function Save-ProviderFile {
    param($Request)
    $provider = Get-ProviderById ([string]$Request.provider_id)
    $relative = [string]$provider.config_file
    if (-not $relative) { throw "供应商未配置 config_file：$($provider.id)" }
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw '配置文件路径超出 PortableAI 根目录' }
    if (Test-Path -LiteralPath $candidate -PathType Container) { throw "配置文件路径是目录，不能直接写入：$relative" }
    $parent = Split-Path -Parent $candidate
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $content = [string]$Request.content
    [IO.File]::WriteAllText($candidate, $content, (New-Object System.Text.UTF8Encoding($true)))
    Write-Log ("provider file updated: " + $provider.id + ' -> ' + $relative)
    return [ordered]@{ provider_id=$provider.id; path=$relative; saved=$true; content=$content }
}
function Get-TailLines {
    param([string]$Name, [int]$Tail = 100)
    $files = @{
        startup = 'startup.log'; service_error = 'service_error.log'; server_cpu_error = 'server-cpu-error.log'; server_vulkan_error = 'server-vulkan-error.log'; server_cuda_error = 'server-cuda-error.log'; control = 'control.log'; gateway = 'anthropic-gateway.log'
    }
    if (-not $files.ContainsKey($Name)) { throw "不支持的日志名：$Name" }
    $path = Join-Path $LogDir $files[$Name]
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $lines = @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
    $count = [math]::Min([math]::Max($Tail, 1), 1000)
    if ($lines.Count -le $count) { return $lines }
    return @($lines[($lines.Count - $count)..($lines.Count - 1)])
}
function Save-Config {
    param($Incoming)
    $current = Get-Config
    $model = [string]$Incoming.model
    if (-not $model -or [IO.Path]::GetFileName($model) -ne $model -or $model -match '[\\/]') { throw '模型名只能是 models 目录中的文件名' }
    $modelPath = Join-Path (Join-Path $Root 'models') $model
    if (-not (Test-Path -LiteralPath $modelPath)) { throw "模型文件不存在：$model" }
    $port = [int]$Incoming.port
    if ($port -lt 1024 -or $port -gt 65535) { throw '模型服务端口必须在 1024 到 65535 之间' }
    $ctx = [int]$Incoming.context
    if ($ctx -lt 512 -or $ctx -gt 131072) { throw 'context 必须在 512 到 131072 之间' }
    $maxTokens = [int]$Incoming.max_tokens
    if ($maxTokens -lt 64 -or $maxTokens -gt 16384) { throw 'max_tokens 必须在 64 到 16384 之间' }
    $temperature = [double]$Incoming.temperature
    if ($temperature -lt 0 -or $temperature -gt 2) { throw 'temperature 必须在 0 到 2 之间' }
    $backend = [string]$Incoming.backend
    if (-not $backend) { $backend = [string]$current.backend }
    if (-not $backend) { $backend = 'auto' }
    if ($backend -notin @('auto','cpu','vulkan','cuda')) { throw 'backend 只能是 auto、cpu、vulkan 或 cuda' }
    $merged = [ordered]@{}
    foreach ($p in $current.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    foreach ($p in $Incoming.PSObject.Properties) { if ($p.Name -notin @('control_port','anthropic_port')) { $merged[$p.Name] = $p.Value } }
    $merged['model'] = $model; $merged['port'] = $port; $merged['context'] = $ctx; $merged['max_tokens'] = $maxTokens; $merged['backend'] = $backend
    $json = $merged | ConvertTo-Json -Depth 10
    Copy-Item -LiteralPath $ConfigPath -Destination ($ConfigPath + '.bak') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $ConfigPath -Value $json -Encoding UTF8
    return Get-Config
}
function Start-ModelProcess {
    $ps = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $ps) { $ps = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source }
    $script = Join-Path $Root 'start.ps1'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-NoBrowser') -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
    Write-Log 'accepted model start request'
}
function Stop-ModelProcess {
    $ps = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $ps) { $ps = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source }
    $script = Join-Path $Root 'stop.ps1'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script) -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
    Write-Log 'accepted model stop request'
}
function Invoke-Action {
    param([string]$Action)
    switch ($Action) {
        'start' { Start-ModelProcess }
        'stop' { Stop-ModelProcess }
        'restart' { Stop-ModelProcess; Start-Sleep -Milliseconds 600; Start-ModelProcess }
        default { throw "不支持的操作：$Action" }
    }
}
function Get-Downstreams {
    param($Config)
    $path = Join-Path $Root 'config\downstreams.json'
    if (Test-Path -LiteralPath $path) {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $key = [string]$Config.agent_api_key
        if (-not $key) { $key = '未启用' }
        foreach ($item in @($data.items)) {
            if ($item.name -eq '本地 OpenAI API') { $item.base_url = "http://127.0.0.1:$($Config.port)/v1" }
            if ($item.name -eq 'Claude Code 适配器') { $item.base_url = "http://127.0.0.1:$($Config.anthropic_port)"; $item.auth = "x-api-key $key" }
            if ($item.name -eq 'Codex / Responses 适配器') { $item.base_url = "http://127.0.0.1:$($Config.anthropic_port)"; $item.auth = "Bearer $key" }
        }
        return $data
    }
    return [pscustomobject]@{ items = @(
        [pscustomobject]@{ name='本地 OpenAI API'; kind='LLAMA SERVER'; protocol='OPENAI'; base_url=("http://127.0.0.1:{0}/v1" -f $Config.port); description='适用于 OpenAI SDK、脚本和支持自定义 Base URL 的工具。'; auth='本机回环（无密钥）'; status='READY' },
        [pscustomobject]@{ name='Claude Code 适配器'; kind='ANTHROPIC BRIDGE'; protocol='MESSAGES'; base_url=("http://127.0.0.1:{0}" -f $Config.anthropic_port); description='将 Anthropic Messages API 转换为本地 OpenAI Chat Completions。'; auth='x-api-key portable-local'; status='READY' },
        [pscustomobject]@{ name='Codex / Responses 适配器'; kind='OPENAI BRIDGE'; protocol='RESPONSES'; base_url=("http://127.0.0.1:{0}" -f $Config.anthropic_port); description='为支持自定义端点的 Codex 类客户端提供 Responses API 兼容入口。'; auth='Bearer portable-local'; status='READY' }
    ) }
}
function Invoke-LocalChat {
    param($Request, $Config)
    if ($null -eq $Request.messages -or @($Request.messages).Count -eq 0) { throw '消息不能为空' }
    $payload = [ordered]@{}
    foreach ($property in $Request.PSObject.Properties) { $payload[$property.Name] = $property.Value }
    if (-not $payload.Contains('model') -or -not $payload.model) { $payload['model'] = [string]$Config.model }
    $payload['stream'] = $false
    $uri = "http://127.0.0.1:$([int]$Config.port)/v1/chat/completions"
    try {
        $body = $payload | ConvertTo-Json -Depth 20
        # Windows PowerShell may encode a string body with the system code page.
        # Send explicit UTF-8 bytes so Chinese prompts reach llama.cpp unchanged.
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $response = Invoke-WebRequest -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing -TimeoutSec 300
        return ($response.Content | ConvertFrom-Json)
    } catch {
        throw ("本地模型请求失败：" + $_.Exception.Message + "；请求地址=" + $uri)
    }
}
function Handle-Api {
    param($Context, [string]$Path, $Config)
    $method = $Context.Request.HttpMethod.ToUpperInvariant()
    if ($Path -eq '/api/config' -and $method -eq 'GET') { return (Send-Json $Context (Get-Config)) }
    if ($Path -eq '/api/config' -and $method -eq 'PUT') { $saved = Save-Config (Read-Body $Context | ConvertFrom-Json); Write-Log 'config updated from control room'; return (Send-Json $Context $saved) }
    if ($Path -eq '/api/environment' -and $method -eq 'GET') { return (Send-Json $Context (Get-EnvironmentSnapshot)) }
    if ($Path -eq '/api/providers' -and $method -eq 'GET') { return (Send-Json $Context (Get-Providers)) }
    if ($Path -eq '/api/providers' -and $method -eq 'PUT') {
        $incoming = Read-Body $Context | ConvertFrom-Json
        $saved = Save-Providers $incoming
        Write-Log 'providers updated from control room'
        return (Send-Json $Context $saved)
    }
    if ($Path -eq '/api/providers/test' -and $method -eq 'POST') {
        $request = Read-Body $Context | ConvertFrom-Json
        return (Send-Json $Context (Invoke-ProviderProbe $request))
    }
    if ($Path -eq '/api/providers/file' -and $method -eq 'GET') {
        $id = Get-QueryValue $Context 'id' ''
        if (-not $id) { throw '缺少供应商 id' }
        return (Send-Json $Context (Get-ProviderFile $id))
    }
    if ($Path -eq '/api/providers/file' -and $method -eq 'PUT') {
        return (Send-Json $Context (Save-ProviderFile (Read-Body $Context | ConvertFrom-Json)))
    }
    if ($Path -eq '/api/status' -and $method -eq 'GET') {
        $health = Get-ModelHealth -LlamaPort ([int]$Config.port); $process = Get-ProcessSnapshot; $modelPath = Join-Path (Join-Path $Root 'models') $Config.model
        $size = if (Test-Path -LiteralPath $modelPath) { [math]::Round((Get-Item -LiteralPath $modelPath).Length / 1GB, 2) } else { 0 }
        return (Send-Json $Context ([ordered]@{ health=$health; process=$process; system=(Get-SystemSnapshot); backend=(Get-BackendName); model=$Config.model; context=[int]$Config.context; max_tokens=[int]$Config.max_tokens; temperature=[double]$Config.temperature; model_size_gb=$size; metrics_enabled=[bool]$Config.metrics; control_port=$Port; model_port=[int]$Config.port; anthropic_port=[int]$Config.anthropic_port }))
    }
    if ($Path -eq '/api/metrics' -and $method -eq 'GET') { return (Send-Json $Context ([ordered]@{ raw=(Get-MetricsText -LlamaPort ([int]$Config.port)) })) }
    if ($Path -eq '/api/logs' -and $method -eq 'GET') { $name=Get-QueryValue $Context 'name' 'startup'; $tail=[int](Get-QueryValue $Context 'tail' '100'); return (Send-Json $Context ([ordered]@{ name=$name; lines=(Get-TailLines -Name $name -Tail $tail) })) }
    if ($Path -eq '/api/downstreams' -and $method -eq 'GET') { return (Send-Json $Context (Get-Downstreams -Config $Config)) }
    if ($Path -eq '/api/action' -and $method -eq 'POST') { $request=Read-Body $Context | ConvertFrom-Json; Invoke-Action -Action ([string]$request.action); return (Send-Json $Context ([ordered]@{ accepted=$true; action=$request.action })) }
    if ($Path -eq '/api/chat' -and $method -eq 'POST') {
        $request = Read-Body $Context | ConvertFrom-Json
        return (Send-Json $Context (Invoke-LocalChat -Request $request -Config $Config))
    }
    if ($Path -eq '/api/ping' -and $method -eq 'GET') { return (Send-Json $Context ([ordered]@{ ok=$true; service='PortableAI control room' })) }
    Send-Json $Context ([ordered]@{ error='API endpoint not found' }) 404
}
function Resolve-StaticFile {
    param([string]$Path)
    if ($Path -eq '/' -or $Path -eq '/index.html') { return (Join-Path $Root 'ui\index.html') }
    if ($Path.StartsWith('/agents/')) { return (Join-Path $Root ($Path.TrimStart('/').Replace('/','\'))) }
    return (Join-Path (Join-Path $Root 'ui') $Path.TrimStart('/').Replace('/','\'))
}
function Get-MimeType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) { '.html' { 'text/html; charset=utf-8'; break } '.js' { 'text/javascript; charset=utf-8'; break } '.css' { 'text/css; charset=utf-8'; break } '.json' { 'application/json; charset=utf-8'; break } '.md' { 'text/markdown; charset=utf-8'; break } default { 'application/octet-stream' } }
}

Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add(("http://127.0.0.1:{0}/" -f $Port))
try {
    $listener.Start(); Write-Log ("control room listening on http://127.0.0.1:{0}" -f $Port)
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            if ($context.Request.HttpMethod -eq 'OPTIONS') { $context.Response.Headers['Access-Control-Allow-Origin']='http://127.0.0.1:' + $Port; $context.Response.Headers['Access-Control-Allow-Methods']='GET,PUT,POST,OPTIONS'; $context.Response.Headers['Access-Control-Allow-Headers']='Content-Type'; Send-Text $context '' 'text/plain' 204; continue }
            $config = Get-Config
            $path = $context.Request.Url.AbsolutePath
            if ($path.StartsWith('/api/')) { Handle-Api -Context $context -Path $path -Config $config; continue }
            $target = Resolve-StaticFile $path
            $fullRoot = [IO.Path]::GetFullPath($Root); $fullTarget = [IO.Path]::GetFullPath($target)
            if (-not $fullTarget.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullTarget -PathType Leaf)) { Send-Text $context 'Not found' 'text/plain' 404; continue }
            Send-Bytes -Context $context -Bytes ([IO.File]::ReadAllBytes($fullTarget)) -ContentType (Get-MimeType $fullTarget)
        } catch { Write-Log ("request error: " + $_.Exception.Message); try { Send-Json $context ([ordered]@{ error=$_.Exception.Message }) 500 } catch { } }
    }
} finally {
    if ($listener) { $listener.Stop(); $listener.Close() }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    Write-Log 'control room stopped'
}



