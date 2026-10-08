$ErrorActionPreference='Stop'
& "$PSScriptRoot/../windows/build.ps1"
if($LASTEXITCODE -ne 0){throw 'Core build failed'}
$project=Resolve-Path "$PSScriptRoot/.."
$resources=Join-Path $project 'desktop/src-tauri/resources/windows'
New-Item -ItemType Directory -Force $resources|Out-Null
foreach($file in @('v6core.exe','wintun.dll','WINTUN-LICENSE.txt','v6only.ps1','desktop-controller.ps1')){Copy-Item "$project/windows/$file" $resources -Force}
Push-Location "$project/core"
try{go build -trimpath -ldflags='-s -w' -o "$project/windows/v6service.exe" ./cmd/v6service;if($LASTEXITCODE -ne 0){throw 'Service build failed'}}finally{Pop-Location}
$env:V6ONLY_SERVICE_EXE="$project/windows/v6service.exe"
Push-Location "$project/desktop"
try{npm ci;if($LASTEXITCODE -ne 0){throw 'npm failed'};npm run tauri -- build --bundles msi;if($LASTEXITCODE -ne 0){throw 'Tauri MSI build failed'}}finally{Pop-Location}
