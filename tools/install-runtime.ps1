$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$downloadDir = Join-Path $Root 'logs\downloads'
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
$headers = @{ 'User-Agent' = 'PortableAI-Setup' }
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10' -Headers $headers
$release = $releases | Where-Object { @($_.assets | Where-Object { $_.name -match 'llama-.*-bin-win-cpu-x64\.zip' }).Count -gt 0 } | Select-Object -First 1
if (-not $release) { throw '没有找到包含 Windows x64 CPU 的 llama.cpp release' }
Write-Host "使用 llama.cpp $($release.tag_name)" -ForegroundColor Cyan
$assets = @{}
foreach ($asset in $release.assets) { $assets[$asset.name] = $asset }
$jobs = @(
    @{ Key='cpu'; Names=@("llama-$($release.tag_name)-bin-win-cpu-x64.zip") },
    @{ Key='cuda'; Names=@("llama-$($release.tag_name)-bin-win-cuda-12.4-x64.zip") },
    @{ Key='vulkan'; Names=@("llama-$($release.tag_name)-bin-win-vulkan-x64.zip") }
)
foreach ($job in $jobs) {
    $dest = Join-Path $Root "runtime\$($job.Key)"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($name in $job.Names) {
        if (-not $assets.ContainsKey($name)) { Write-Host "跳过缺失资产：$name" -ForegroundColor Yellow; continue }
        $asset = $assets[$name]
        $archive = Join-Path $downloadDir $name
        if (-not (Test-Path $archive) -or (Get-Item $archive).Length -ne [int64]$asset.size) {
            Write-Host "下载 $name ($([math]::Round($asset.size/1MB,1)) MB)" -ForegroundColor Cyan
            & curl.exe -L --fail --retry 3 --retry-delay 5 --progress-bar --output "$archive" "$($asset.browser_download_url)"
            if ($LASTEXITCODE -ne 0) { throw "下载失败：$name" }
        }
        if ($asset.digest -match '^sha256:(.+)$') {
            $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $Matches[1].ToLowerInvariant()) { throw "校验失败：$name" }
        }
        $temp = Join-Path $downloadDir ("extract-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $temp | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $temp -Force
        $server = Get-ChildItem -LiteralPath $temp -Filter 'llama-server.exe' -File -Recurse | Select-Object -First 1
        if (-not $server) { throw "压缩包内找不到 llama-server.exe：$name" }
        Copy-Item -Path (Join-Path $server.Directory.FullName '*') -Destination $dest -Recurse -Force
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
Write-Host '运行时安装完成。' -ForegroundColor Green

