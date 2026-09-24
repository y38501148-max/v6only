$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '../core')
try {
    go build -trimpath -ldflags='-s -w' -o (Join-Path $PSScriptRoot 'v6core.exe') ./cmd/v6core
    if ($LASTEXITCODE -ne 0) { throw 'Go build failed' }
} finally { Pop-Location }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('v6only-wintun-' + [guid]::NewGuid())
New-Item -ItemType Directory $temp | Out-Null
try {
    $archive = Join-Path $temp 'wintun.zip'
    Invoke-WebRequest 'https://www.wintun.net/builds/wintun-0.14.1.zip' -OutFile $archive
    # Published by wintun.net, pinned to the supported signed redistributable.
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51') { throw 'Wintun checksum mismatch' }
    Expand-Archive $archive $temp
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    Copy-Item "$temp/wintun/bin/$arch/wintun.dll" "$PSScriptRoot/wintun.dll" -Force
    Copy-Item "$temp/wintun/LICENSE.txt" "$PSScriptRoot/WINTUN-LICENSE.txt" -Force
} finally { Remove-Item $temp -Recurse -Force }
