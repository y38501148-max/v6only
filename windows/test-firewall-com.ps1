# Only run on disposable Windows CI: validate the actual helpers used by PR #18.
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'v6only.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-V6FirewallRule','New-V6FirewallRule','Remove-V6FirewallRule')){
 $fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false)
 if(!$fn){throw "Missing helper $name"}
 . ([scriptblock]::Create($fn.Extent.Text))
}
$prefix='ci-v6only-com-'+[guid]::NewGuid().ToString('N')
$adapter=Get-NetAdapter|Where-Object Status -eq 'Up'|Select-Object -First 1
if(!$adapter){throw 'No active adapter'}
try{
 foreach($protocol in @('UDP','TCP')){
  $name=$prefix+'-'+$protocol
  New-V6FirewallRule -DisplayName $name -Direction Outbound -Action Block -Protocol $protocol -RemotePort 53535 -RemoteAddress @('192.0.2.53','198.51.100.53') -InterfaceAlias $adapter.Name -Profile Any
  $found=@(Get-V6FirewallRule -DisplayName $name)
  if($found.Count -ne 1 -or $found[0].Enabled -ne 'True'){throw 'COM rule lookup failed'}
  $native=Get-NetFirewallRule -DisplayName $name
  if($native.Direction -ne 'Outbound' -or $native.Action -ne 'Block'){throw 'Rule behavior changed'}
  $port=$native|Get-NetFirewallPortFilter
  if($port.Protocol -ne $protocol -or $port.RemotePort -ne '53535'){throw 'Protocol/port filter changed'}
  $address=$native|Get-NetFirewallAddressFilter
  if(@($address.RemoteAddress).Count -ne 2){throw 'Address filter changed'}
  $iface=$native|Get-NetFirewallInterfaceFilter
  if($iface.InterfaceAlias -notcontains $adapter.Name){throw 'Interface scope changed'}
 }
 Get-V6FirewallRule -DisplayName ($prefix+'*')|Remove-V6FirewallRule
 if(@(Get-V6FirewallRule -DisplayName ($prefix+'*')).Count -ne 0){throw 'COM cleanup failed'}
 Write-Host 'PASS: real COM firewall UDP/TCP behavior, interface scope and cleanup'
}finally{
 Get-V6FirewallRule -DisplayName ($prefix+'*')|Remove-V6FirewallRule
}
