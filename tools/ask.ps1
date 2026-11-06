param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Prompt
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Config = Get-Content (Join-Path $Root 'config\config.json') -Raw | ConvertFrom-Json
$body = @{
    model = $Config.model
    messages = @(@{ role = 'user'; content = $Prompt })
    max_tokens = [int]$Config.max_tokens
    temperature = 0.2
    stream = $false
    chat_template_kwargs = @{ enable_thinking = $false }
} | ConvertTo-Json -Depth 10
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$response = Invoke-RestMethod -Uri "http://127.0.0.1:$($Config.port)/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $bodyBytes -TimeoutSec 300
$response.choices[0].message.content
