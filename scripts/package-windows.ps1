$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$version=(Get-Content "$root/VERSION" -Raw).Trim()
$out="$root/build/release/v6only-windows-x64-$version"
New-Item -ItemType Directory -Force "$out/windows" | Out-Null
& "$root/windows/build.ps1"
Copy-Item "$root/windows/v6only.ps1","$root/windows/v6core.exe","$root/windows/wintun.dll","$root/windows/WINTUN-LICENSE.txt" "$out/windows/"
Copy-Item "$root/README.md","$root/LICENSE","$root/VERSION" "$out/"
python "$PSScriptRoot/collect-licenses.py" "$out/third-party"
if ($LASTEXITCODE) {throw 'License collection failed'}
git -C $root rev-parse HEAD | Set-Content "$out/COMMIT"
Compress-Archive $out "$root/build/release/v6only-windows-x64-$version.zip" -Force
