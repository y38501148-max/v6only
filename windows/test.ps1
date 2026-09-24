# Pure policy + controller regression tests with mocked Windows APIs.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'v6only.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($fn in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$checks = 0
function Assert($condition, $label) {
    if (-not $condition) { throw "FAIL: $label" }
    $script:checks++
}
Assert (Test-CampusEvidence '202.112.128.50' '' '') 'exact campus DNS'
Assert (Test-CampusEvidence '1.1.1.1,202.112.128.51' '' '') 'second DHCP DNS'
Assert (Test-CampusEvidence '' 'dept.BUAA.EDU.CN.' '') 'campus domain boundary'
Assert (Test-CampusEvidence '' '' 'BUAA-mobile') 'campus profile'
Assert (-not (Test-CampusEvidence '10.0.0.1' '' 'Home')) 'private network is not campus'
Assert (-not (Test-CampusEvidence '202.112.1.1' 'buaa.edu.cn.evil.example' 'BUAAFake')) 'no loose prefix matching'

$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $temp | Out-Null
$Marker=Join-Path $temp 'active'; $Snapshot=Join-Path $temp 'original.json'
$SuspendFlg=Join-Path $temp 'suspend'; $LogFile=Join-Path $temp 'log'
$ManagedDns=@('202.112.128.50','202.112.128.51','2400:3200::1')
$BlockedDnsV4=@('8.8.8.8','8.8.4.4','1.1.1.1','9.9.9.9')
$Watch=$true; $Suspend=$null
$FakeAdapter=[pscustomobject]@{ifIndex=7;Name='Wi-Fi';InterfaceGuid=[guid]::Empty;Status='Up';HardwareInterface=$true}
$FakeDhcp='10.0.0.1'; $FakeDns=@('9.9.9.9'); $FakeWrites=0; $FakeRules=@{}
function Write-Log($msg) {}
function Get-ActiveAdapter { return $FakeAdapter }
function Get-NetAdapter { return $FakeAdapter }
function Get-ItemProperty { return [pscustomobject]@{DhcpNameServer=$FakeDhcp;DhcpDomain='';NameServer='9.9.9.9'} }
function Get-NetConnectionProfile { return [pscustomobject]@{Name='Home'} }
function Get-NetIPAddress { return [pscustomobject]@{IPAddress='2400:abcd::1'} }
function Get-DnsClientServerAddress { return [pscustomobject]@{ServerAddresses=$FakeDns} }
function Set-DnsClientServerAddress {
    param($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses)
    $script:FakeWrites++
    $script:FakeDns=if ($ResetServerAddresses) { @('192.168.1.1') } else { @($ServerAddresses) }
}
function Get-NetFirewallRule {
    param($DisplayName)
    foreach ($key in @($FakeRules.Keys)) { if ($key -like $DisplayName) { $FakeRules[$key] } }
}
function New-NetFirewallRule {
    param($DisplayName,$Direction,$Action,$Protocol,$RemotePort,$RemoteAddress,$InterfaceAlias,$Profile)
    $script:FakeWrites++
    $script:FakeRules[$DisplayName]=[pscustomobject]@{DisplayName=$DisplayName;Enabled='True'}
}
function Remove-NetFirewallRule {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { if ($InputObject) { $script:FakeWrites++; $script:FakeRules.Remove($InputObject.DisplayName) } }
}
$FakeTask = [pscustomobject]@{State='Running'}
$TaskDisabled=$false; $TaskStopped=$false
function Get-ScheduledTask { return $FakeTask }
function Disable-ScheduledTask { $script:TaskDisabled=$true }
function Stop-ScheduledTask { $script:TaskStopped=$true; $script:FakeTask.State='Ready' }
try {
    Stop-V6Task
    Assert ($TaskDisabled -and $TaskStopped -and $FakeTask.State -ne 'Running') 'old scheduled watcher is disabled and stopped'
    $FakeTask=$null
    Stop-V6Task
    Assert ($null -eq $FakeTask) 'fresh install without existing task is supported'
    Invoke-V6On
    Assert ($FakeWrites -eq 0) 'manual On outside campus has no network writes'
    Assert (-not (Test-Path $Marker)) 'outside campus has no active marker'
    $FakeDhcp='202.112.128.50'
    Invoke-V6On
    Assert (($FakeDns -join ',') -eq ($ManagedDns -join ',')) 'campus DNS applied'
    Assert (Test-Path $Snapshot) 'previous settings captured'
    $writes=$FakeWrites
    Invoke-V6On
    Assert ($FakeWrites -eq $writes) 'repeated On does not write'
    $FakeDhcp='10.0.0.1'
    Invoke-V6On
    Assert (($FakeDns -join ',') -eq '9.9.9.9') 'leaving campus restores original DNS'
    Assert ($FakeRules.Count -eq 0) 'leaving removes only tool firewall rules'
    Assert (-not (Test-Path $Marker)) 'leaving clears active marker'
    Assert (-not (Test-Path $SuspendFlg)) 'automatic departure does not suspend return'
    $FakeDhcp='202.112.128.51'
    Invoke-V6On
    Assert (Test-Path $Marker) 'return to campus reapplies'
    $FakeDns=@('1.0.0.1')
    Invoke-V6Off
    Assert (($FakeDns -join ',') -eq '1.0.0.1') 'Off preserves later user DNS edits'
    Assert (Test-Suspended $SuspendFlg) 'manual Off pauses watcher'
    (Get-Date).AddSeconds(-1).ToString('o') | Set-Content $SuspendFlg
    Assert (-not (Test-Suspended $SuspendFlg)) 'pause expires'
    Assert (-not (Test-Path $SuspendFlg)) 'expired pause removed'
    $FakeDns=@('240c::6666','202.112.128.50','2400:3200::1')
    New-Item -ItemType File -Path $Marker | Out-Null
    Invoke-V6On
    Assert ((Get-Content $Snapshot -Raw | ConvertFrom-Json).AutomaticDns) 'known legacy default migrates to DHCP restoration'
    Invoke-V6Off -Automatic
    Assert (($FakeDns -join ',') -eq '192.168.1.1') 'leaving campus after upgrade restores network DHCP DNS'
    $FakeDns=@('240c::6666','202.112.128.50','2400:3200::1')
    Invoke-V6On
    Assert (-not (Get-Content $Snapshot -Raw | ConvertFrom-Json).AutomaticDns) 'matching user DNS without a legacy marker is preserved'
    Invoke-V6Off -Automatic
    Write-Host "PASS: $checks Windows campus/controller regression checks"
} finally {
    Remove-Item $temp -Recurse -Force
}
