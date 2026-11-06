$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$inputPath = Join-Path $Root 'documents\inbox'
$outputPath = Join-Path $Root 'documents\extracted'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$files = Get-ChildItem -LiteralPath $inputPath -File
if (-not $files) { Write-Host "请把 .docx、.txt、.md、.csv 或代码文件放入：$inputPath"; exit 0 }
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($file in $files) {
    $out = Join-Path $outputPath ($file.BaseName + '.txt')
    if ($file.Extension -ieq '.docx') {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
        try {
            $entry = $zip.GetEntry('word/document.xml')
            if (-not $entry) { throw "找不到 Word 文档主体：$($file.Name)" }
            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                $xml = [xml]$reader.ReadToEnd()
                $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
                $lines = foreach ($p in $xml.SelectNodes('//w:p',$ns)) {
                    (($p.SelectNodes('.//w:t',$ns) | ForEach-Object { $_.'#text' }) -join '')
                }
                $lines | Set-Content -LiteralPath $out -Encoding UTF8
            } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
    } else {
        Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | Set-Content -LiteralPath $out -Encoding UTF8
    }
    Write-Host "已提取：$($file.Name) -> $out" -ForegroundColor Green
}
