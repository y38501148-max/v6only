# Issue #15: execute real controller functions with isolated files and fake OS APIs.
$ErrorActionPreference='Stop'
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'v6only.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('v6only-dns-'+[guid]::NewGuid())
New-Item -ItemType Directory $temp|Out-Null
$Marker=Join-Path $temp 'active.flag';$Snapshot=Join-Path $temp 'original.json';$CoreState=Join-Path $temp 'core.json'
$SuspendFlg=Join-Path $temp 'suspend';$Watch=$true;$Desktop=$true;$Suspend=$null
$ManagedDns=@('127.0.0.1');$BlockedDnsV4=@('8.8.8.8');$checks=0
$physical=[pscustomobject]@{Name='Wi-Fi';ifIndex=7;InterfaceGuid=[guid]::NewGuid()}
$present=$true;$core=$false;$stops=0;$rules=@{};$writes=0;$failFamily=''
$dns=@{IPv4=@('127.0.0.1');IPv6=@()}
$reg=@{IPv4=[pscustomobject]@{NameServer='127.0.0.1';EnableDHCP=1;DhcpNameServer='202.112.128.51 202.112.128.50'};IPv6=[pscustomobject]@{NameServer=''}}
function Assert($ok,$label){if(!$ok){throw "FAIL: $label"};$script:checks++}
function Write-Log($msg){}
function Get-ActiveAdapter {if($present){$physical}}
function Get-NetAdapter {if($present){$physical}}
function Test-CampusNetwork {return $false,''}
function Get-NetIPAddress { [pscustomobject]@{IPAddress='2400:abcd::1'} }
function Get-ItemProperty($Path){if($Path -like '*Tcpip6*'){$reg.IPv6}else{$reg.IPv4}}
function Get-DnsClientServerAddress {
 param($InterfaceIndex,$AddressFamily)
 $families=if($AddressFamily){@($AddressFamily)}else{@('IPv4','IPv6')}
 foreach($family in $families){[pscustomobject]@{Family=$family;ServerAddresses=@($dns[$family])}}
}
function Set-DnsClientServerAddress {
 param($InputObject,$InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses)
 $script:writes++
 $families=if($InputObject){@($InputObject.Family)}else{@('IPv4','IPv6')}
 foreach($family in $families){
  if($family -eq $failFamily){throw 'Simulated restore error'}
  $dns[$family]=if($ResetServerAddresses){if($family -eq 'IPv4'){@('202.112.128.51','202.112.128.50')}else{@()}}else{@($ServerAddresses|Where-Object{($_ -match ':') -eq ($family -eq 'IPv6')})}
 }
}
function Test-CoreActive {return $core}
function Start-V6Core { $script:core=$true }
function Stop-V6Core { $script:core=$false;$script:stops++ }
function Test-Forwarding {}
function Get-V6FirewallRule {param($DisplayName);foreach($name in @($rules.Keys)){if($name -like $DisplayName){$rules[$name]}}}
function New-V6FirewallRule {param($DisplayName,$Direction,$Action,$Protocol,$RemotePort,$RemoteAddress,$InterfaceAlias,$Profile);$rules[$DisplayName]=[pscustomobject]@{DisplayName=$DisplayName;Enabled='True'}}
function Remove-V6FirewallRule {param([Parameter(ValueFromPipeline)]$InputObject);process{if($InputObject){$rules.Remove($InputObject.DisplayName)}}}
function PoisonedSnapshot {
 [pscustomobject]@{InterfaceGuid=[string]$physical.InterfaceGuid;AutomaticDns=$false;OriginalDns=@('127.0.0.1');AppliedDns=@('127.0.0.1');PreviousAppliedDns=@('127.0.0.1')}|ConvertTo-Json|Set-Content $Snapshot
 $dns.IPv4=@('127.0.0.1');$dns.IPv6=@();$script:core=$true
}
try {
 Invoke-V6On
 $saved=Get-Content $Snapshot -Raw|ConvertFrom-Json
 Assert ($saved.SchemaVersion -eq 2 -and $saved.DnsFamilies.Count -eq 2) 'atomic snapshot includes both address families'
 Assert (-not (Test-LocalDns $saved.OriginalDns)) 'orphan loopback never becomes original DNS'
 Assert ($saved.AutomaticDns) 'DHCP DNS evidence repairs orphan loopback'
 Assert (-not (Test-LocalDns @(Get-AdapterDns $physical))) 'active desktop keeps physical DNS usable'
 Invoke-V6Off -Automatic
 Assert (!$core -and !(Test-Path $Snapshot) -and !(Test-LocalDns @(Get-AdapterDns $physical))) 'On then Off cannot leave a stopped core as DNS'
 PoisonedSnapshot
 Invoke-V6Off -Automatic
 Assert (!(Test-LocalDns @(Get-AdapterDns $physical)) -and !(Test-Path $Snapshot)) 'old contaminated snapshot is repaired during disable'

 $dns.IPv4=@('9.9.9.9');$dns.IPv6=@('2001:db8::53')
 $reg.IPv4=[pscustomobject]@{NameServer='9.9.9.9';EnableDHCP=1;DhcpNameServer='202.112.128.50'}
 $reg.IPv6=[pscustomobject]@{NameServer=''}
 $state=New-DnsSnapshot $physical @(Get-AdapterDns $physical)
 Assert (!$state.DnsFamilies[0].Automatic -and $state.DnsFamilies[1].Automatic) 'IPv4 static and IPv6 automatic remain distinct'
 $state.AppliedDns=@('202.112.128.50','2400:3200::1');Write-DnsSnapshot $state
 $dns.IPv4=@('202.112.128.50');$dns.IPv6=@('2001:db8::999')
 Invoke-V6Off -Automatic
 Assert (($dns.IPv4 -join ',') -eq '9.9.9.9') 'restore owned IPv4 family'
 Assert (($dns.IPv6 -join ',') -eq '2001:db8::999') 'preserve a later IPv6 user edit'

 $state.AppliedDns=@('9.9.9.9');Write-DnsSnapshot $state
 $present=$false;$core=$true;$before=$stops
 $rules['v6only-block-external-dns']=[pscustomobject]@{DisplayName='v6only-block-external-dns'}
 $failed=$false;try{Invoke-V6Off -Automatic}catch{$failed=$true}
 Assert ($failed -and (Test-Path $Snapshot)) 'missing interface preserves recovery snapshot'
 Assert (!$core -and $stops -eq $before+1 -and $rules.Count -eq 0) 'missing interface still stops core and removes owned firewall rules'
 $present=$true;Invoke-V6Off -Automatic
 Assert (!(Test-Path $Snapshot)) 'pending restoration finishes when interface returns'

 '{broken'|Set-Content $Snapshot;$core=$true;$before=$stops
 $failed=$false;try{Invoke-V6Off -Automatic}catch{$failed=$true}
 Assert ($failed -and !$core -and $stops -eq $before+1 -and (Test-Path $Snapshot)) 'unreadable snapshot cannot skip independent cleanup'
 Remove-Item $Snapshot
 PoisonedSnapshot
 $reg.IPv4=[pscustomobject]@{NameServer='127.0.0.1';EnableDHCP=0;DhcpNameServer=''}
 $failed=$false;try{Invoke-V6Off -Automatic}catch{$failed=$true}
 Assert ($failed -and !$core -and (Test-Path $Snapshot)) 'unproven original settings are retained with an actionable error'
 Assert (($dns.IPv4 -join ',') -eq '127.0.0.1') 'no guessed public DNS replaces an unknown static configuration'
 Remove-Item $Snapshot
 $state=[pscustomobject]@{InterfaceGuid=[string]$physical.InterfaceGuid;OriginalDns=@('9.9.9.9');AppliedDns=@('202.112.128.50','2400:3200::1');DnsFamilies=@([pscustomobject]@{Family='IPv4';Automatic=$false;Servers=@('9.9.9.9')},[pscustomobject]@{Family='IPv6';Automatic=$true;Servers=@()})}
 Write-DnsSnapshot $state
 $dns.IPv4=@('202.112.128.50');$dns.IPv6=@('2400:3200::1');$failFamily='IPv4';$core=$true
 $failed=$false;try{Invoke-V6Off -Automatic}catch{$failed=$true}
 Assert ($failed -and !$core -and (Test-Path $Snapshot)) 'one DNS family failure retains recovery and still stops the core'
 Assert ($dns.IPv6.Count -eq 0) 'other DNS family restores independently after an IPv4 failure'
 Write-Host "PASS: $checks DNS snapshot and independent cleanup checks"
} finally {Remove-Item $temp -Recurse -Force}
