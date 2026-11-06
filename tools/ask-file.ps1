param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$File,
    [string]$Instruction = '请阅读以下文件，提炼重点并指出需要修改或核对的地方。',
    [string]$Output
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not [System.IO.Path]::IsPathRooted($File)) { $File = Join-Path $Root $File }
if (-not (Test-Path -LiteralPath $File)) { throw "文件不存在：$File" }
$text = Get-Content -LiteralPath $File -Raw -Encoding UTF8
$limit = 50000
if ($text.Length -gt $limit) { $text = $text.Substring(0,$limit) + "

[文件内容超过 50000 个字符，当前版本只处理前半部分]" }
$prompt = "$Instruction

--- 文件内容开始 ---
$text
--- 文件内容结束 ---"
$Config = Get-Content (Join-Path $Root 'config\config.json') -Raw | ConvertFrom-Json
$body = @{
    model = $Config.model
    messages = @(@{ role = 'user'; content = $prompt })
    max_tokens = [int]$Config.max_tokens
    temperature = 0.2
    stream = $false
    chat_template_kwargs = @{ enable_thinking = $false }
} | ConvertTo-Json -Depth 10
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$response = Invoke-RestMethod -Uri "http://127.0.0.1:$($Config.port)/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $bodyBytes -TimeoutSec 600
$answer = $response.choices[0].message.content
if ($Output) {
    if (-not [System.IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $Root $Output }
    $answer | Set-Content -LiteralPath $Output -Encoding UTF8
    Write-Host "已写入：$Output" -ForegroundColor Green
} else { $answer }
