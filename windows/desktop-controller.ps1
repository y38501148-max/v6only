param([ValidateSet('status','enable','disable','watch','stop')][string]$Action='status')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# Load the controller without invoking its CLI entry point.
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'v6only.ps1'),[ref]$null,[ref]$null)
$functions=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)
foreach($fn in $functions){. ([scriptblock]::Create($fn.Extent.Text))}
$Desktop=$true; $Watch=$true
$dir=Join-Path $env:ProgramData 'v6only'
New-Item -ItemType Directory -Force $dir | Out-Null
$Marker=Join-Path $dir 'active.flag';$Snapshot=Join-Path $dir 'original.json';$SuspendFlg=Join-Path $dir 'suspend.flag'
$LogFile=Join-Path $dir 'v6only.log';$CoreReady=Join-Path $dir 'core.ready';$CoreState=Join-Path $dir 'core-process.json';$CoreDir=$PSScriptRoot
$ManagedDns=@('127.0.0.1');$BlockedDnsV4=@('8.8.8.8','8.8.4.4','1.1.1.1','9.9.9.9')
$enabled=Join-Path $dir 'enabled.flag'
switch($Action){
 'enable' {New-Item -ItemType File -Force $enabled|Out-Null;Remove-Item $SuspendFlg -Force -ErrorAction SilentlyContinue;Invoke-V6On}
 'disable' {Remove-Item $enabled -Force -ErrorAction SilentlyContinue;Invoke-V6Off -Automatic}
 'stop' {Invoke-V6Off -Automatic}
 'watch' {
   if((Test-Path $enabled) -and -not (Test-Suspended $SuspendFlg)){
     $adapter=Get-ActiveAdapter
     if($adapter){Invoke-V6On}
     elseif(Test-Path $Snapshot){Invoke-V6Off -Automatic}
   }
 }
}
if($Action -in @('status','enable','disable')){
 # Enumerate the parsed array into a new array. PowerShell 5.1 adds
 # extended properties even to ConvertFrom-Json arrays; wrapping that
 # object in @() alone leaves a nested {value, Count} object in the UI.
 $health=$null;$flows=@();try{$health=Invoke-RestMethod http://127.0.0.1:17890/health -TimeoutSec 2;$parsedFlows=ConvertFrom-Json -InputObject ((Invoke-WebRequest -UseBasicParsing http://127.0.0.1:17890/flows -TimeoutSec 2).Content);$flows=@(foreach($flow in $parsedFlows){$flow})}catch{}
 $adapter=Get-ActiveAdapter
 $physicalDns=@();if(Test-Path $Snapshot){$physicalDns=@((Get-Content $Snapshot -Raw|ConvertFrom-Json).OriginalDns)}elseif($adapter){$physicalDns=@(Get-AdapterDns $adapter)}
 $addresses=@(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue|Where-Object IPAddress -Match '^[23][0-9a-fA-F]{3}:')
 $logs=if(Test-Path $LogFile){(Get-Content $LogFile -Tail 30)-join "`n"}else{''}
 $logs+="`n";if(Test-Path (Join-Path $dir 'core-error.log')){$logs+=(Get-Content (Join-Path $dir 'core-error.log') -Tail 20)-join "`n"}
 @{interface_name=$adapter.Name;dns=$physicalDns;installed=$true;enabled=((Test-Path $Marker) -and (Test-CoreActive));suspended=(!(Test-Path $enabled) -or (Test-Suspended $SuspendFlg));health=$health;flows=$flows;ipv6_interface=(($addresses|ForEach-Object {'inet6 '+$_.IPAddress})-join "`n");proxy='';pac='';logs=$logs;version='2.1.2'}|ConvertTo-Json -Depth 12 -Compress
}
