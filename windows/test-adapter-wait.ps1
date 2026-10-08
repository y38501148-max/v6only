# Reproduce successful WMI queries returning an adapter that is not ready yet.
$ErrorActionPreference='Stop'
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'v6only.ps1'),[ref]$null,[ref]$null)
$fn=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-ForwardingAdapter'},$false)
. ([scriptblock]::Create($fn[0].Extent.Text))
$ticks=0
function Start-Sleep { param($Milliseconds) $script:ticks++ }
function Get-NetAdapter { param($Name,$ErrorAction) [pscustomobject]@{Status=$(if($ticks -lt 2){'Disconnected'}else{'Up'});ifIndex=42} }
function Get-NetIPInterface {
 param($InterfaceIndex,$ErrorAction)
 [pscustomobject]@{AddressFamily='IPv4'}
 if($ticks -ge 3){[pscustomobject]@{AddressFamily='IPv6'}}
}
$adapter=Wait-ForwardingAdapter 'v6only-tun'
if($adapter.ifIndex -ne 42 -or $ticks -ne 3){throw 'Adapter registration did not wait for both families'}
$ticks=0
function Get-NetAdapter { param($Name,$ErrorAction) throw 'WMI registration pending' }
$failed=$false
try{Wait-ForwardingAdapter 'v6only-tun'}catch{$failed=$true}
if(!$failed -or $ticks -ne 40){throw 'Missing adapter retry was not bounded'}
Write-Host 'PASS: delayed Wintun adapter/IP registration and bounded failure'
