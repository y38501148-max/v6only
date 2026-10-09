# Exercise the real desktop watch and activation logic with mocked network APIs.
# No administrator privileges, network changes, or real core process are needed.
$ErrorActionPreference = 'Stop'
foreach ($file in @('v6only.ps1', 'desktop-controller.ps1')) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $file), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    if ($file -eq 'v6only.ps1') {
        foreach ($fn in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    } else {
        $switch = $ast.Find({$args[0] -is [System.Management.Automation.Language.SwitchStatementAst]}, $true)
        $actions = @{}
        foreach ($clause in $switch.Clauses) {
            $body = $clause.Item2.Extent.Text
            $actions[$clause.Item1.Value] = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
        }
    }
}
$checks = 0
function Assert($condition, $label) {
    if (-not $condition) { throw "FAIL: $label" }
    $script:checks++
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('v6only-retry-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory $temp | Out-Null
$Marker = Join-Path $temp 'active.flag'; $Snapshot = Join-Path $temp 'original.json'
$SuspendFlg = Join-Path $temp 'suspend.flag'; $enabled = Join-Path $temp 'enabled.flag'
$Desktop = $true; $Watch = $true; $Suspend = $null
$ManagedDns = @('127.0.0.1'); $BlockedDnsV4 = @('8.8.8.8')
$FakePhysical = [pscustomobject]@{Name='Wi-Fi';ifIndex=7;InterfaceGuid=[guid]::Empty}
$FakeAdapter = $null; $FakeDns = @('192.168.1.1'); $FakeRules = @{}
$FakeCore = $false; $FailCore = $false; $FailDns = $false; $Attempts = 0; $Logs = @()
$FakeNow = [datetime]::Now
function Get-Date { return $script:FakeNow }
function Write-Log($msg) { $script:Logs += $msg }
function Get-ActiveAdapter { return $script:FakeAdapter }
function Get-NetAdapter { return $script:FakePhysical }
function Test-CampusNetwork { return $false, '' }
function Get-NetIPAddress { return [pscustomobject]@{IPAddress='2400:abcd::1'} }
function Get-ItemProperty { return [pscustomobject]@{NameServer='192.168.1.1'} }
function Get-DnsClientServerAddress { return [pscustomobject]@{ServerAddresses=$script:FakeDns} }
function Set-DnsClientServerAddress {
    param($InterfaceIndex, $ServerAddresses, [switch]$ResetServerAddresses)
    $script:FakeDns = if ($ResetServerAddresses) { @('192.168.1.1') } else { @($ServerAddresses) }
    if ($script:FailDns) {
        $script:FailDns = $false
        throw 'Simulated DNS configuration failure'
    }
}
function Test-CoreActive { return $script:FakeCore }
function Start-V6Core {
    $script:Attempts++
    $script:FakeCore = $true
    if ($script:FailCore) { throw 'Simulated core readiness timeout' }
}
function Stop-V6Core { $script:FakeCore = $false }
function Get-NetFirewallRule {
    param($DisplayName)
    foreach ($key in @($script:FakeRules.Keys)) {
        if ($key -like $DisplayName) { $script:FakeRules[$key] }
    }
}
function New-NetFirewallRule {
    param($DisplayName, $Direction, $Action, $Protocol, $RemotePort, $RemoteAddress, $InterfaceAlias, $Profile)
    $script:FakeRules[$DisplayName] = [pscustomobject]@{DisplayName=$DisplayName;Enabled='True'}
}
function Remove-NetFirewallRule {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { if ($InputObject) { $script:FakeRules.Remove($InputObject.DisplayName) } }
}
try {
    New-Item -ItemType File $enabled | Out-Null
    . $actions['watch']
    Assert ($Attempts -eq 0 -and -not (Test-Path $SuspendFlg)) 'offline boot waits without suspending'
    $FakeAdapter = $FakePhysical
    . $actions['watch']
    Assert ($FakeCore -and (Test-Path $Marker)) 'later network connection starts forwarding'
    $FakeAdapter = $null
    . $actions['watch']
    Assert (-not $FakeCore -and -not (Test-Path $Snapshot)) 'network loss restores the old configuration'
    Assert (Test-Path $enabled) 'automatic restoration preserves enabled intent'

    $FakeAdapter = $FakePhysical; $FailCore = $true
    $failed = $false
    try { . $actions['watch'] } catch { $failed = $true }
    Assert $failed 'startup error is propagated'
    Assert (-not $FakeCore -and -not (Test-Path $Marker) -and -not (Test-Path $Snapshot)) 'startup failure rolls back and stops the core'
    Assert (($FakeDns -join ',') -eq '192.168.1.1' -and $FakeRules.Count -eq 0) 'startup failure restores DNS and firewall rules'
    Assert (Test-Path $enabled) 'startup failure preserves enabled intent'
    $retryAt = [datetime]::Parse((Get-Content $SuspendFlg -Raw).Trim())
    Assert ($retryAt -eq $FakeNow.AddSeconds(60)) 'startup failure schedules a finite 60-second retry'
    Assert (($Logs -join ',') -match 'Simulated core readiness timeout') 'startup error and retry are logged'
    $attemptsBefore = $Attempts
    $FakeNow = $FakeNow.AddSeconds(59)
    . $actions['watch']
    Assert ($Attempts -eq $attemptsBefore) 'watch does not retry during the cooldown'

    $FakeNow = $FakeNow.AddSeconds(1)
    $failed = $false
    try { . $actions['watch'] } catch { $failed = $true }
    Assert ($failed -and $Attempts -eq $attemptsBefore + 1) 'persistent failure is retried after expiry'
    Assert ([datetime]::Parse((Get-Content $SuspendFlg -Raw).Trim()) -eq $FakeNow.AddSeconds(60)) 'repeated failure renews the cooldown'
    $FailCore = $false; $FakeNow = $FakeNow.AddSeconds(60)
    . $actions['watch']
    Assert ($FakeCore -and (Test-Path $Marker) -and -not (Test-Path $SuspendFlg)) 'recovered environment resumes without UI interaction'

    Invoke-V6Off -Automatic
    '' | Set-Content $SuspendFlg -Encoding UTF8
    . $actions['watch']
    Assert ($FakeCore -and -not (Test-Path $SuspendFlg)) 'old empty desktop failure marker is migrated'
    Invoke-V6Off
    $attemptsBefore = $Attempts
    . $actions['watch']
    Assert ($Attempts -eq $attemptsBefore -and (Test-Suspended $SuspendFlg)) 'manual timed pause is respected'
    . $actions['enable']
    Assert ($FakeCore -and -not (Test-Path $SuspendFlg)) 'explicit enable bypasses a pause'

    Invoke-V6Off -Automatic
    $FailDns = $true; $failed = $false
    try { . $actions['watch'] } catch { $failed = $true }
    Assert ($failed -and -not $FakeCore -and ($FakeDns -join ',') -eq '192.168.1.1') 'failure after DNS modification also restores the network'
    Assert (Test-Suspended $SuspendFlg) 'DNS setup failure enters a bounded cooldown'
    . $actions['disable']
    Assert (-not (Test-Path $enabled)) 'manual disable during cooldown clears enabled intent'
    '' | Set-Content $SuspendFlg -Encoding UTF8
    $FakeNow = $FakeNow.AddMinutes(31); $attemptsBefore = $Attempts
    . $actions['watch']
    Assert ($Attempts -eq $attemptsBefore -and -not $FakeCore -and -not (Test-Path $enabled)) 'manual disable stays disabled even with a legacy marker'
    Assert (-not (Test-Suspended $SuspendFlg)) 'empty desktop marker expires'
    'invalid-nonempty-pause' | Set-Content $SuspendFlg
    Assert (Test-Suspended $SuspendFlg) 'nonempty malformed pause remains conservative'
    '' | Set-Content $SuspendFlg
    $Desktop = $false
    Assert (Test-Suspended $SuspendFlg) 'legacy campus watcher retains its indefinite failure pause'
    Write-Host "PASS: $checks desktop startup/retry regression checks"
} finally {
    Get-ChildItem -LiteralPath $temp -File | Remove-Item -Force
    Remove-Item -LiteralPath $temp -Force
}
