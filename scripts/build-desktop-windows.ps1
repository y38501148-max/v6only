$ErrorActionPreference='Stop'
& "$PSScriptRoot/../windows/build.ps1"
if($LASTEXITCODE -ne 0){throw 'Core build failed'}
$project=Resolve-Path "$PSScriptRoot/.."
$resources=Join-Path $project 'desktop/src-tauri/resources/windows'
New-Item -ItemType Directory -Force $resources|Out-Null
foreach($file in @('v6core.exe','wintun.dll','WINTUN-LICENSE.txt','v6only.ps1','desktop-controller.ps1')){Copy-Item "$project/windows/$file" $resources -Force}
Push-Location "$project/core"
try{go build -trimpath -ldflags='-s -w' -o "$project/windows/v6service.exe" ./cmd/v6service;if($LASTEXITCODE -ne 0){throw 'Service build failed'}}finally{Pop-Location}
$env:TAURI_V6ONLY_SERVICE_EXE="$project/windows/v6service.exe"
Push-Location "$project/desktop"
try{npm ci;if($LASTEXITCODE -ne 0){throw 'npm failed'};npm run tauri -- build --bundles msi --verbose
 if($LASTEXITCODE -ne 0){
  $candle=Join-Path $env:LOCALAPPDATA 'tauri/WixTools314/candle.exe'
  if(Test-Path $candle){& $candle -arch x64 -out "$project/build/service-test.wixobj" "$project/desktop/src-tauri/wix/service.wxs"}
  throw 'Tauri MSI build failed'
 }}finally{Pop-Location}
