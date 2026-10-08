$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable GitHub Windows VM required'}
$out=Join-Path $PSScriptRoot '../build/msi-test';New-Item -ItemType Directory -Force $out|Out-Null
$msi=Get-ChildItem "$PSScriptRoot/../desktop/src-tauri/target/release/bundle/msi/*.msi"|Select-Object -First 1
if(!$msi){throw 'No MSI generated'}
$baselineIndexes=@((Get-NetAdapter|Where-Object HardwareInterface).ifIndex)
$baseline=@(Get-DnsClientServerAddress|Where-Object InterfaceIndex -in $baselineIndexes|Select-Object InterfaceIndex,AddressFamily,ServerAddresses)|ConvertTo-Json -Depth 5 -Compress
function RPC($request){
 $pipe=[IO.Pipes.NamedPipeClientStream]::new('.','v6only-desktop',[IO.Pipes.PipeDirection]::InOut)
 try{$pipe.Connect(10000);$writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true;$writer.WriteLine(($request|ConvertTo-Json -Compress));$reader=[IO.StreamReader]::new($pipe);$reply=$reader.ReadLine()|ConvertFrom-Json;if(!$reply.ok){throw $reply.error};return $reply.data}finally{$pipe.Dispose()}
}
try{
 $p=Start-Process msiexec.exe -ArgumentList "/i `"$($msi.FullName)`" /qn /norestart /l*v `"$out/install.log`"" -Wait -PassThru
 if($p.ExitCode -notin @(0,3010)){throw "MSI install failed: $($p.ExitCode)"}
 $service=Get-Service V6Only;if($service.Status -ne 'Running'){throw 'Installed service is not running'}
 RPC @{action='status'}|ConvertTo-Json -Depth 12|Set-Content "$out/status.json"
 $bad=$false;try{RPC @{action='arbitrary-shell';url='whoami'}}catch{$bad=$true};if(!$bad){throw 'RPC allowlist missing'}
 $installed=Join-Path $env:ProgramFiles 'V6Only'
 $gui=Get-ChildItem $installed -Filter '*.exe'|Where-Object Name -ne 'v6service.exe'|Select-Object -First 1
 if(!$gui){throw 'Desktop executable missing'}
 $app=Start-Process $gui.FullName -PassThru;Start-Sleep 5;if($app.HasExited){throw 'Desktop GUI exited during launch'};Stop-Process $app.Id -Force
 # Exercise actual Wintun global capture. Hosted VM has no external IPv6;
 # successful connection to a literal IPv4 proves the v4-only path remains usable.
 RPC @{action='enable'}|ConvertTo-Json -Depth 12|Set-Content "$out/enabled.json"
 if(!(RPC @{action='status'}).enabled){throw 'Network controller did not enable'}
 & curl.exe --noproxy '*' -fsS --max-time 20 http://1.1.1.1/ -o NUL
 if($LASTEXITCODE){throw 'Physical IPv4 through Wintun failed'}
 Start-Sleep 2
 $stats=RPC @{action='stats';from=0;to=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+1}
 if(($stats.v4_up+$stats.v4_down) -le 0){throw 'Traffic counters were not persisted'}
 $stats|ConvertTo-Json -Depth 12|Set-Content "$out/stats.json"
 RPC @{action='disable'}|Out-Null
 $saved=$stats.v4_up+$stats.v4_down
 if(((RPC @{action='stats';from=0;to=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+1}).v4_up) -lt $stats.v4_up){throw 'Stopped history disappeared'}
 # Uninstall while active to verify service-stop cleanup as well as service removal.
 RPC @{action='enable'}|Out-Null
}finally{
 $p=Start-Process msiexec.exe -ArgumentList "/x `"$($msi.FullName)`" /qn /norestart /l*v `"$out/uninstall.log`"" -Wait -PassThru
 if($p.ExitCode -notin @(0,3010)){throw "MSI uninstall failed: $($p.ExitCode)"}
}
if(Get-Service V6Only -ErrorAction SilentlyContinue){throw 'Service left behind after uninstall'}
$after=@(Get-DnsClientServerAddress|Where-Object InterfaceIndex -in $baselineIndexes|Select-Object InterfaceIndex,AddressFamily,ServerAddresses)|ConvertTo-Json -Depth 5 -Compress
if($baseline -ne $after){throw 'DNS was not restored after uninstall'}
$owned=Get-NetAdapter -Name 'v6only-tun' -ErrorAction SilentlyContinue
if($owned -and @(Get-NetRoute -InterfaceIndex $owned.ifIndex -ErrorAction SilentlyContinue|Where-Object DestinationPrefix -in @('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')).Count){throw 'Owned routes left behind'}
Write-Host 'PASS: MSI installation, service IPC, GUI launch, Wintun IPv4, persistent traffic, uninstall and DNS/routes recovery'
