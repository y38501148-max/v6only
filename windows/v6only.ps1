#Requires -Version 5.1
<#
.SYNOPSIS
    v6only for Windows — 校园网感知 v6 优先守护 (v2)
.DESCRIPTION
    与 macOS 端同构：
      - 仅校园网生效；保留系统 IPv4/IPv6 地址选择，不强制使用 IPv6
      - v4-only 站点直连 IPv4，不受影响
      - 封外部 IPv4 明文 DNS（防硬编码 8.8.8.8 绕过解析策略）
      - 校园 DNS（202.112.128.0/24、10/8 网关型）放行
    检测信号（任一命中即校园网）：
      - 物理接口的 DHCP DNS 精确匹配校园 DNS
      - DHCP 域名边界匹配 buaa.edu.cn
      - 当前物理网络配置文件名匹配校园 SSID
    计划任务开机自启；-Suspend 30 分钟不干预（对应用户手动回滚）
.NOTES
    需要管理员权限。适用：Windows 10 1903+ / Windows 11
#>

[CmdletBinding(DefaultParameterSetName = 'Watch')]
param(
    [Parameter(ParameterSetName='Watch')] [switch]$Watch,
    [switch]$Desktop,
    [switch]$On,            # 应用 v6 优先配置
    [switch]$Off,           # 回滚（并挂起守护 30 分钟）
    [switch]$Test,          # 生效性验证
    [switch]$Install,       # 注册开机自启计划任务
    [switch]$Uninstall,     # 卸载守护
    [string]$Suspend        # 挂起分钟数（配合 -Off 自动使用 30）
)

$ErrorActionPreference = 'Stop'
$Marker     = "$env:ProgramData\v6only\active.flag"
$SuspendFlg = "$env:ProgramData\v6only\suspend.flag"
$LogFile    = "$env:ProgramData\v6only\v6only.log"
$DnsV6Primary = '2400:3200::1'        # Public fallback; DNS transport does not force IPv6
$Snapshot = "$env:ProgramData\v6only\original.json"
$ManagedDns = @('202.112.128.50','202.112.128.51')
$CoreDir = $PSScriptRoot
$CoreReady = Join-Path (Split-Path $Marker) 'core.ready'
$CoreState = Join-Path (Split-Path $Marker) 'core-process.json'
$DnsCampusV4  = '202.112.128.50'      # 校园 v4 兜底（v4-only 域名查 A）
$BlockedDnsV4 = @('8.8.8.8','8.8.4.4','1.1.1.1','9.9.9.9')  # 外部 v4 明文 DNS 封堵名单

function Write-Log([string]$msg) {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File $LogFile -Append -Encoding utf8
}

# NetSecurity cmdlets enumerate the whole policy store on every call, which
# takes tens of seconds on hosts with large rule sets and overruns the service
# timeout. The COM policy object is equivalent (rule Name == DisplayName) and
# answers in well under a second.
function Get-V6FirewallRule {
    [CmdletBinding()] param([string]$DisplayName)
    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    # Materialize before returning so piped removals never mutate a live enumeration.
    $found = @(foreach ($rule in $policy.Rules) {
        if ($rule.Name -like $DisplayName) {
            [pscustomobject]@{DisplayName=$rule.Name; Enabled=[string]$rule.Enabled}
        }
    })
    $found
}
function Remove-V6FirewallRule {
    param([Parameter(ValueFromPipeline)]$InputObject)
    begin { $policy = New-Object -ComObject HNetCfg.FwPolicy2 }
    process { if ($InputObject) { $policy.Rules.Remove($InputObject.DisplayName) } }
}
function New-V6FirewallRule {
    [CmdletBinding()] param($DisplayName, $Direction, $Action, $Protocol, $RemotePort, $RemoteAddress, $InterfaceAlias, $Profile)
    $rule = New-Object -ComObject HNetCfg.FWRule
    $rule.Name = $DisplayName
    $rule.Direction = if ($Direction -eq 'Inbound') { 1 } else { 2 }
    $rule.Action = if ($Action -eq 'Allow') { 1 } else { 0 }
    $rule.Protocol = if ($Protocol -eq 'TCP') { 6 } else { 17 }
    $rule.RemotePorts = [string]$RemotePort
    $rule.RemoteAddresses = @($RemoteAddress) -join ','
    $rule.Interfaces = [object[]]@($InterfaceAlias)
    $rule.Profiles = 0x7FFFFFFF
    $rule.Enabled = $true
    (New-Object -ComObject HNetCfg.FwPolicy2).Rules.Add($rule)
}

function Stop-V6Task([string]$TaskName = 'v6only-watch') {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }
    # Unregistering/replacing a task alone does not stop its running process.
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Stop-ScheduledTask -TaskName $TaskName
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task -or $task.State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    }
    throw "Cannot stop $TaskName; refusing to race the existing network watcher."
}

function Test-LegacyDns([string[]]$Dns) {
    return (($Dns | Sort-Object) -join ',') -eq '202.112.128.50,2400:3200::1,240c::6666'
}

function Test-CoreActive {
    if (-not (Test-Path $CoreReady) -or -not (Test-Path $CoreState)) { return $false }
    try {
        $saved = Get-Content $CoreState -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.Pid -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks -ne $saved.StartTicks) { return $false }
        if ($Desktop -and $saved.NetworkSignature -ne (Get-PhysicalNetworkSignature (Get-ActiveAdapter))) { return $false }
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17890/health' -TimeoutSec 2
        $tun = Get-NetAdapter -Name 'v6only-tun' -ErrorAction Stop
        $routes = @(Get-NetRoute -InterfaceIndex $tun.ifIndex -ErrorAction Stop)
        return $health.policy -in @('ipv6-only-unless-no-aaaa','ipv6-preferred-with-ipv4-fallback') -and
            @($routes | Where-Object DestinationPrefix -in @('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')).Count -eq 4
    } catch { return $false }
}

function Get-PhysicalNetworkSignature($Adapter) {
    if (-not $Adapter) { return '' }
    $addresses = @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop | ForEach-Object { $_.IPAddress } | Sort-Object)
    $gateways = @(Get-NetRoute -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop | Where-Object DestinationPrefix -in @('0.0.0.0/0','::/0') | ForEach-Object { $_.NextHop } | Sort-Object)
    return ([string]$Adapter.InterfaceGuid) + '|' + ($addresses -join ',') + '|' + ($gateways -join ',') + '|' + (@(Get-AdapterDns $Adapter) -join ',')
}

function Stop-V6Core {
    $stopError = $null
    try {
    if (Test-Path $CoreState) {
        $saved = Get-Content $CoreState -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.Pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq $saved.StartTicks -and $process.ProcessName -eq 'v6core') {
            Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(10000) | Out-Null
        }
    }
    } catch { $stopError = $_; Write-Log "Core state/process cleanup: $_`n$($_.ScriptStackTrace)" }
    # Routes belong exclusively to the named adapter owned by this program.
    $tun = Get-NetAdapter -Name 'v6only-tun' -ErrorAction SilentlyContinue
    if ($tun) { Get-NetRoute -InterfaceIndex $tun.ifIndex -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item $CoreReady,$CoreState -Force -ErrorAction SilentlyContinue
    if ($stopError) { throw $stopError }
}

function Wait-ForwardingAdapter([string]$Name) {
    # Driver readiness precedes WMI registration; the previous adapter's
    # registry key may still be pending deletion during a quick restart.
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        try {
            $adapter=Get-NetAdapter -Name $Name -ErrorAction Stop
            $interfaces=@(Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -ErrorAction Stop)
            if($adapter.Status -eq 'Up' -and @($interfaces|Where-Object AddressFamily -in @('IPv4','IPv6')).Count -ge 2){return $adapter}
        }
        catch { }
        # WMI can return the adapter successfully before it is Up or before
        # both IP interfaces exist. Those states need the same retry delay.
        Start-Sleep -Milliseconds 250
    }
    throw "Forwarding adapter $Name is unavailable after driver start"
}

function Invoke-BoundedProcess([string]$File, [string]$Arguments, [string]$OutputPath, [string]$ErrorPath, [int]$TimeoutMs = 15000) {
    # Own the native process handle from creation. Start-Process's redirected
    # Process objects can return a null ExitCode on Windows PowerShell 5.1.
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName=$File; $info.Arguments=$Arguments; $info.UseShellExecute=$false
    $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $outputTask=$process.StandardOutput.ReadToEndAsync()
        $errorTask=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Physical DNS/HTTPS probe timed out before network takeover'
        }
        [IO.File]::WriteAllText($OutputPath, $outputTask.GetAwaiter().GetResult())
        [IO.File]::WriteAllText($ErrorPath, $errorTask.GetAwaiter().GetResult())
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Test-PhysicalForwarding($Adapter, [string[]]$Upstream, [string]$Supplement) {
    # Independent HTTPS origins prevent a single IPv6/CDN outage from disabling
    # an otherwise healthy network. Every attempt retains the selected policy.
    $lastError = ''
    foreach ($url in @('https://www.bilibili.com/','https://www.microsoft.com/')) {
        $arguments = '--interface "' + $Adapter.Name + '" --dns ' + ($Upstream -join ',') + ' --ipv6-dns ' + $Supplement + ' --probe ' + $url
        if (Test-Path (Join-Path (Split-Path $Marker) 'allow-ipv4-fallback.flag')) { $arguments += ' --allow-ipv4-fallback' }
        try {
            $exitCode = Invoke-BoundedProcess (Join-Path $CoreDir 'v6core.exe') $arguments `
                (Join-Path (Split-Path $Marker) 'preflight.json') (Join-Path (Split-Path $Marker) 'preflight-error.log') 12000
            if ($exitCode -eq 0) { return }
            $lastError = "exit $exitCode"
        } catch { $lastError = $_.Exception.Message }
        Write-Log "Physical HTTPS check failed for ${url}: $lastError"
    }
    throw "Physical DNS/HTTPS checks failed before network takeover: $lastError; see preflight-error.log"

}

function Start-V6Core($Adapter) {
    if (Test-CoreActive) { return }
    foreach ($file in @('v6core.exe','wintun.dll')) {
        if (-not (Test-Path (Join-Path $CoreDir $file))) { throw "Missing release component: $file" }
    }
    Stop-V6Core
    $args = '--interface "' + $Adapter.Name + '" --device v6only-tun --dns 202.112.128.50,202.112.128.51 --ready "' + $CoreReady + '"'
    if ($Desktop) {
        $upstream = @($ManagedDns | Where-Object { -not (Test-LocalDns @($_)) })
        if (-not $upstream) { $upstream = @('223.5.5.5','223.6.6.6') }
        $supplement='223.5.5.5,223.6.6.6'
        if(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue|Where-Object IPAddress -Match '^[23][0-9a-fA-F]{3}:'){$supplement='2400:3200::1,2400:3200:baba::1,223.5.5.5,223.6.6.6'}
        Test-PhysicalForwarding $Adapter $upstream $supplement
        $args = '--interface "' + $Adapter.Name + '" --device v6only-tun --dns ' + ($upstream -join ',') + ' --ipv6-dns ' + $supplement + ' --chatgpt-ipv4 --stats-db "' + (Join-Path (Split-Path $Marker) 'traffic.sqlite') + '" --ready "' + $CoreReady + '"'
    }
    if (Test-Path (Join-Path (Split-Path $Marker) 'allow-ipv4-fallback.flag')) { $args += ' --allow-ipv4-fallback' }
    $process = Start-Process -FilePath (Join-Path $CoreDir 'v6core.exe') -ArgumentList $args -WorkingDirectory $CoreDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path (Split-Path $Marker) 'core.log') -RedirectStandardError (Join-Path (Split-Path $Marker) 'core-error.log')
    $null = $process.Handle
    if ($process.HasExited) { throw 'Forwarding core exited before process state capture; see core-error.log' }
    @{Pid=$process.Id;StartTicks=$process.StartTime.ToUniversalTime().Ticks;NetworkSignature=(Get-PhysicalNetworkSignature $Adapter)} | ConvertTo-Json | Set-Content $CoreState
    for ($i=0; $i -lt 40; $i++) {
        if (Test-Path $CoreReady) { break }
        if ($process.HasExited) { throw 'Forwarding core exited during start' }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path $CoreReady)) { throw 'Forwarding core readiness timeout' }
    $tun = Wait-ForwardingAdapter 'v6only-tun'
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv4 -Dhcp Disabled
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv4 -DadTransmits 0
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv6 -DadTransmits 0
    New-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress '198.18.0.1' -PrefixLength 24 | Out-Null
    New-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress 'fd00:198:18::1' -PrefixLength 64 | Out-Null
    for ($i=0;$i -lt 40;$i++) {
        if ((Get-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress '198.18.0.1').AddressState -eq 'Preferred') { break }
        Start-Sleep -Milliseconds 250
    }
    if ((Get-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress '198.18.0.1').AddressState -ne 'Preferred') { throw 'Wintun address not ready' }
    foreach ($prefix in @('0.0.0.0/1','128.0.0.0/1')) {
        New-NetRoute -InterfaceIndex $tun.ifIndex -DestinationPrefix $prefix -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
    }
    foreach ($prefix in @('::/1','8000::/1')) {
        New-NetRoute -InterfaceIndex $tun.ifIndex -DestinationPrefix $prefix -NextHop '::' -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
    }
    if (-not (Test-CoreActive)) { throw 'Forwarding core route verification failed' }
}

function Get-ActiveAdapter {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if (-not $routes) { $routes = @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue) }
    foreach ($route in ($routes | Sort-Object { $_.RouteMetric + $_.InterfaceMetric })) {
        $adapter = Get-NetAdapter | Where-Object {
            $_.ifIndex -eq $route.InterfaceIndex -and $_.Status -eq 'Up' -and $_.HardwareInterface
        } | Select-Object -First 1
        if ($adapter) { return $adapter }
    }
    return $null
}

function Test-CampusEvidence([string]$DhcpDns, [string]$Domain, [string]$Profile) {
    foreach ($ip in ($DhcpDns -split '[,;\s]+')) {
        if ($ip -in @('202.112.128.50','202.112.128.51')) { return $true }
    }
    foreach ($suffix in ($Domain -split '[,;\s]+')) {
        if ($suffix.TrimEnd('.') -match '(^|\.)buaa\.edu\.cn$') { return $true }
    }
    return $Profile -match '^BUAA($|[-_])'
}

function Test-CampusNetwork($Adapter = (Get-ActiveAdapter)) {
    if (-not $Adapter) { return $false, '' }
    $guid = ([guid]$Adapter.InterfaceGuid).ToString('B')
    # Read DHCP evidence, not the static DNS values written by this program.
    $lease = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -ErrorAction SilentlyContinue
    $profile = (Get-NetConnectionProfile -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue |
        Select-Object -First 1).Name
    $matched = Test-CampusEvidence $lease.DhcpNameServer $lease.DhcpDomain $profile
    return $matched, "interface=$($Adapter.Name)"
}

function Get-AdapterDns($Adapter) {
    return @((Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop).ServerAddresses |
        Where-Object { $_ } | Select-Object -Unique)
}

function Write-DnsSnapshot($State) {
    # Same-volume replacement leaves either the previous or the complete new JSON.
    $temp = "$Snapshot.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content $temp -Encoding UTF8
        if (Test-Path $Snapshot) { [IO.File]::Replace($temp, $Snapshot, "$Snapshot.previous") }
        else { [IO.File]::Move($temp, $Snapshot) }
    } finally { Remove-Item $temp,"$Snapshot.previous" -Force -ErrorAction SilentlyContinue }
}

function Test-LocalDns([string[]]$Dns) {
    foreach ($value in $Dns) {
        $ip = $null
        if ([net.ipaddress]::TryParse($value, [ref]$ip) -and
            ([net.ipaddress]::IsLoopback($ip) -or $ip.Equals([net.ipaddress]::Any) -or $ip.Equals([net.ipaddress]::IPv6Any))) { return $true }
    }
    return $false
}

function New-DnsSnapshot($Adapter, [string[]]$Current, [switch]$RepairLocal) {
    $guid = ([guid]$Adapter.InterfaceGuid).ToString('B')
    $families = @(foreach ($family in @('IPv4','IPv6')) {
        $service = if ($family -eq 'IPv4') { 'Tcpip' } else { 'Tcpip6' }
        $registry = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$guid" -ErrorAction Stop
        $static = @(([string]$registry.NameServer -split '[,;\s]+') | Where-Object { $_ })
        $automatic = $static.Count -eq 0
        if ((Test-Path $Marker) -and (Test-LegacyDns $Current)) { $automatic = $true }
        if ($RepairLocal -and (Test-LocalDns $static)) {
            # A DHCP address configuration alone does not establish DNS intent.
            # Require actual non-local DHCP DNS evidence on this same interface.
            $leaseDns = @(([string]$registry.DhcpNameServer -split '[,;\s]+') | Where-Object { $_ })
            if ($family -ne 'IPv4' -or $registry.EnableDHCP -ne 1 -or -not $leaseDns -or (Test-LocalDns $leaseDns)) {
                throw "Cannot safely recover $family local DNS on $($Adapter.Name); snapshot retained. Configure the original DNS manually."
            }
            $automatic = $true
            Write-Log "Recovered contaminated $family DNS snapshot using DHCP evidence on $guid"
        }
        [pscustomobject]@{Family=$family;Automatic=$automatic;Servers=$static}
    })
    [pscustomobject]@{
        SchemaVersion=2;InterfaceGuid=[string]$Adapter.InterfaceGuid
        AutomaticDns=(@($families | Where-Object { -not $_.Automatic }).Count -eq 0)
        OriginalDns=@($Current | Where-Object { -not (Test-LocalDns @($_)) })
        DnsFamilies=$families;AppliedDns=@($ManagedDns)
    }
}

function Restore-AdapterDns($Adapter, $State, [switch]$CheckOwned) {
    if ($State.DnsFamilies) {
        $familyError = $null
        foreach ($family in $State.DnsFamilies) {
            try {
            $inputDns = Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily $family.Family -ErrorAction Stop
            if ($CheckOwned) {
                $currentFamily = @($inputDns.ServerAddresses) -join ','
                $expected = @($State.AppliedDns | Where-Object { ($_ -match ':') -eq ($family.Family -eq 'IPv6') }) -join ','
                $previous = @($State.PreviousAppliedDns | Where-Object { ($_ -match ':') -eq ($family.Family -eq 'IPv6') }) -join ','
                if ($currentFamily -ne $expected -and $currentFamily -ne $previous) { continue }
            }
            if ($family.Automatic) { Set-DnsClientServerAddress -InputObject $inputDns -ResetServerAddresses }
            else { Set-DnsClientServerAddress -InputObject $inputDns -ServerAddresses @($family.Servers) }
            } catch { $familyError = $_; Write-Log "Pending $($family.Family) DNS restoration: $_" }
        }
        if ($familyError) { throw $familyError }
    } elseif ($State.AutomaticDns) { Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses }
    else { Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses @($State.OriginalDns) }
}

function Test-Forwarding {

    $urls = if ($Desktop) { @('https://www.bilibili.com/','https://www.microsoft.com/') } else { @('https://gw.buaa.edu.cn/','https://www.bilibili.com/') }
    $lastError = $null
    foreach ($url in $urls) {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.Proxy = $null
        $request.Method = 'HEAD'
        $request.Timeout = 8000
        try { $response = $request.GetResponse(); $response.Close() }
        catch [System.Net.WebException] {
            # An authenticated HTTP error still proves the DNS/TLS/TCP path.
            if ($_.Exception.Response) { $_.Exception.Response.Close() }
            elseif ($Desktop) { $lastError = $_; Write-Log "Forwarded HTTPS check failed for ${url}: $_"; continue }
            else { throw }
        }
        if ($Desktop) { return }
    }
    if ($Desktop) { throw $lastError }

}

function Invoke-V6On {
    $adapter = Get-ActiveAdapter
    $campus, $why = Test-CampusNetwork $adapter
    if (-not $campus -and -not $Desktop) {
        if ((Test-Path $Marker) -or (Test-Path $Snapshot)) { Invoke-V6Off -Automatic }
        Write-Log 'outside campus: no configuration applied'
        return
    }
    if (-not $adapter) { throw 'No active physical network adapter' }
    $v6addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -match '^[23][0-9a-fA-F]{3}:' | Select-Object -First 1
    if (-not $v6addr -and -not (Test-Path (Join-Path (Split-Path $Marker) 'allow-ipv4-fallback.flag'))) {
        if ((Test-Path $Snapshot) -or (Test-Path $CoreState)) { Invoke-V6Off -Automatic }
        Write-Log "Waiting for global IPv6 on $($adapter.Name); system network preserved"
        return
    }
    $state = if (Test-Path $Snapshot) { Get-Content $Snapshot -Raw | ConvertFrom-Json } else { $null }
    if ($state -and $state.InterfaceGuid -ne [string]$adapter.InterfaceGuid) {
        Invoke-V6Off -Automatic
        if (Test-Path $Snapshot) { throw 'Original interface still needs DNS restoration; refusing to overwrite its snapshot.' }
        $state = $null
    }
    $current = @(Get-AdapterDns $adapter)
    if ($state -and (Test-LocalDns $current) -and -not (Test-LocalDns @($state.OriginalDns)) -and
        ($current -join ',') -eq ($state.AppliedDns -join ',')) {
        Restore-AdapterDns $adapter $state
        $current = @(Get-AdapterDns $adapter)
    }
    # Repair old poisoned snapshots before any new takeover. With no snapshot,
    # do not assume a third-party local DNS listener belongs to V6Only unless
    # matching DHCP evidence permits a safe recovery.
    if (($state -and (Test-LocalDns @($state.OriginalDns))) -or (-not $state -and (Test-LocalDns $current))) {
        $repair = New-DnsSnapshot $adapter $current -RepairLocal
        Write-DnsSnapshot $repair
        Restore-AdapterDns $adapter $repair
        $current = @(Get-AdapterDns $adapter)
        $repair.OriginalDns = $current
        Write-DnsSnapshot $repair
        $state = $repair
    }
    if ($Desktop) {
        # TUN intercepts DNS while active. Physical resolvers remain usable if
        # the process crashes, just as on macOS; never install loopback DNS.
        $script:ManagedDns = @($current | Where-Object { -not (Test-LocalDns @($_)) })
        if (-not $ManagedDns) { throw 'Waiting for physical DNS servers' }
    }
    $udp = Get-V6FirewallRule -DisplayName 'v6only-block-external-dns' -ErrorAction SilentlyContinue
    $tcp = Get-V6FirewallRule -DisplayName 'v6only-block-external-dns-tcp' -ErrorAction SilentlyContinue
    if ($state -and ($current -join ',') -eq ($ManagedDns -join ',') -and
        $udp.Enabled -eq 'True' -and $tcp.Enabled -eq 'True' -and (Test-Path $Marker) -and (Test-CoreActive)) {
        Remove-Item $SuspendFlg -Force -ErrorAction SilentlyContinue
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Marker) | Out-Null
    if (-not $state) {
        $state = New-DnsSnapshot $adapter $current
        Write-DnsSnapshot $state
    }
    $state | Add-Member -NotePropertyName PreviousAppliedDns -NotePropertyValue @($state.AppliedDns) -Force
    $state.AppliedDns = $ManagedDns
    Write-DnsSnapshot $state
    try {
        Start-V6Core $adapter
        if (-not $Desktop) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $ManagedDns }
        foreach ($protocol in @('UDP','TCP')) {
            $name = if ($protocol -eq 'UDP') { 'v6only-block-external-dns' } else { 'v6only-block-external-dns-tcp' }
            Get-V6FirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-V6FirewallRule
            $blocked = @($BlockedDnsV4 | Where-Object { -not $Desktop -or $_ -notin $ManagedDns })
            if (-not $blocked) { continue }
            New-V6FirewallRule -DisplayName $name -Direction Outbound -Action Block `
                -Protocol $protocol -RemotePort 53 -RemoteAddress $blocked `
                -InterfaceAlias $adapter.Name -Profile Any | Out-Null
        }
        if ((@(Get-AdapterDns $adapter) -join ',') -ne ($ManagedDns -join ',')) { throw 'DNS readback mismatch' }
        New-Item -ItemType File -Force -Path $Marker | Out-Null
        Test-Forwarding
        Remove-Item $SuspendFlg -Force -ErrorAction SilentlyContinue
        Write-Log "campus configuration applied ($why)"
    } catch {
        $startupError = $_
        Write-Log "Startup error: $startupError`n$($startupError.ScriptStackTrace)"
        try { Invoke-V6Off -Automatic } catch { Write-Log "Rollback error: $_`n$($_.ScriptStackTrace)" }
        if ($Desktop) {
            # Keep the user's enabled state, but give a transient startup failure
            # time to recover before the service's next takeover attempt.
            (Get-Date).AddSeconds(60).ToString('o') | Set-Content $SuspendFlg -Encoding UTF8
            Write-Log "Forwarding startup failed; retry in 60 seconds: $_"
        } else {
            '' | Set-Content $SuspendFlg -Encoding UTF8
        }
        throw $startupError
    }
    if (-not $Watch) { Write-Host '转发已启用。' }
}

function Invoke-V6Off([switch]$Automatic) {
    $restoreError = $null
    try {
    if (Test-Path $Snapshot) {
        $state = Get-Content $Snapshot -Raw | ConvertFrom-Json
        $adapter = Get-NetAdapter | Where-Object { [string]$_.InterfaceGuid -eq $state.InterfaceGuid } | Select-Object -First 1
        if (-not $adapter) { throw 'Original interface is unavailable; keeping snapshot for restoration.' }
        if (Test-LocalDns @($state.OriginalDns)) {
            $repaired = New-DnsSnapshot $adapter @(Get-AdapterDns $adapter) -RepairLocal
            $repaired.AppliedDns = $state.AppliedDns
            $repaired | Add-Member PreviousAppliedDns @($state.PreviousAppliedDns) -Force
            Write-DnsSnapshot $repaired
            $state = $repaired
        }
        $current = @(Get-AdapterDns $adapter) -join ','
        if ($state.DnsFamilies) { Restore-AdapterDns $adapter $state -CheckOwned }
        elseif ($current -eq ($state.AppliedDns -join ',') -or $current -eq ($state.PreviousAppliedDns -join ',')) {
            Restore-AdapterDns $adapter $state
        }
    } elseif (Test-Path $Marker) {
        # Legacy releases did not save a snapshot. Reset only their exact DNS profile.
        foreach ($adapter in (Get-NetAdapter)) {
            $dns = @(Get-AdapterDns $adapter)
            if (Test-LegacyDns $dns) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
            } elseif (Test-LocalDns $dns) {
                $repair = New-DnsSnapshot $adapter $dns -RepairLocal
                Write-DnsSnapshot $repair
                Restore-AdapterDns $adapter $repair
            }
        }
    }
    } catch { $restoreError = $_; Write-Log "DNS restore pending: $_`n$($_.ScriptStackTrace)" }
    # Every cleanup step runs even if the original interface is absent or the
    # snapshot is unreadable. Failed restoration keeps the recovery information.
    try { Stop-V6Core } catch { if (-not $restoreError) { $restoreError = $_ }; Write-Log "Core cleanup failed: $_" }
    try { Get-V6FirewallRule -DisplayName 'v6only-block-external-dns*' -ErrorAction SilentlyContinue | Remove-V6FirewallRule }
    catch { if (-not $restoreError) { $restoreError = $_ }; Write-Log "Firewall cleanup failed: $_" }
    Remove-Item $Marker -Force -ErrorAction SilentlyContinue
    if (-not $restoreError) { Remove-Item $Snapshot -Force -ErrorAction SilentlyContinue }
    if (-not $Automatic) {
        $minutes = if ($Suspend) { [int]$Suspend } else { 30 }
        New-Item -ItemType Directory -Force -Path (Split-Path $SuspendFlg) | Out-Null
        (Get-Date).AddMinutes($minutes).ToString('o') | Set-Content $SuspendFlg -Encoding UTF8
    }
    Write-Log 'campus configuration removed'
    if ($restoreError) { throw $restoreError }
}

function Test-Suspended([string]$path, [switch]$ReadOnly) {
    if (-not (Test-Path $path)) { return $false }
    $until = Get-Content $path -Raw
    # Older desktop releases wrote an empty marker after startup failures.
    # Manual desktop disable removes enabled.flag; timed manual pauses still
    # use a valid timestamp and must retain their original meaning.
    if ($Desktop -and [string]::IsNullOrWhiteSpace($until)) {
        if (-not $ReadOnly) { Remove-Item $path -Force }
        return $false
    }
    try {
        if ((Get-Date) -ge [datetime]::Parse($until.Trim())) {
            if (-not $ReadOnly) { Remove-Item $path -Force }
            return $false
        }
    } catch { return $true }
    return $true
}

function Invoke-Test {
    $script:fail = 0
    $script:passed = 0
    function Ok($m){ Write-Host "  [PASS] $m"; $script:passed++ }
    function Bad($m){ Write-Host "  [FAIL] $m"; $script:fail++ }

    Write-Host "=== v6only Windows 验证 ==="
    $campus, $reason = Test-CampusNetwork
    if (-not $campus) {
        if ((Test-Path $Marker) -or (Test-Path $Snapshot)) { Bad '非校园网仍有待回滚状态' }
        else { Ok '非校园网，校园配置未生效' }
        exit $script:fail
    }
    $v6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
          Where-Object IPAddress -match '^[23][0-9a-fA-F]{3}:' | Select-Object -First 1
    if ($v6) { Ok "全球 v6 = $($v6.IPAddress)" } else { Bad "无 2001:: v6 地址" }

    if (Test-CoreActive) { Ok 'IPv6 优先转发核心和路由就绪' } else { Bad '转发核心未完整运行' }

    try {
        $r = Resolve-DnsName www.edu.cn -Type AAAA -Server $DnsCampusV4 -DnsOnly -ErrorAction Stop
        Ok "校园 DNS 解析 AAAA = $($r[0].IPAddress)"
    } catch { Bad '校园 DNS 的 AAAA 解析失败' }

    try {
        $r = Resolve-DnsName mirrors.ustc.edu.cn -Type A -Server $DnsCampusV4 -DnsOnly -ErrorAction Stop
        Ok "校园 v4 DNS 解析 A = $($r[0].IPAddress)"
    } catch { Bad "校园 v4 DNS 不可达" }

    $blocked = $true
    try { Resolve-DnsName www.baidu.com -Server 8.8.8.8 -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null; $blocked = $false } catch {}
    if ($blocked) { Ok "外部 v4 DNS (8.8.8.8) 已封" } else { Bad "8.8.8.8 仍可查询" }

    $conn = Test-NetConnection codeforces.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($conn) { Ok "codeforces.com:443 可达" } else { Bad "codeforces.com 不可达" }
    $k = Test-NetConnection kedaya.ai -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($k) { Ok "kedaya.ai:443 可达" } else { Bad "kedaya.ai 不可达" }

    if (Test-Path $Marker) { Ok "v6 优先模式标记存在" } else { Bad "无 active 标记" }
    Write-Host "=== 结果：通过 $script:passed 项 / 失败 $script:fail 项 ==="
    exit $script:fail
}

# ── 主入口 ──
switch ($true) {
    $Test      { Invoke-Test }
    $On        { Invoke-V6On }
    $Off       { Invoke-V6Off }
    $Install {
        Stop-V6Task
        if ((Test-Path $Snapshot) -or (Test-Path $CoreState)) { Invoke-V6Off -Automatic }
        foreach ($file in @('v6core.exe','wintun.dll')) {
            if (-not (Test-Path (Join-Path $PSScriptRoot $file))) { throw "Missing release component: $file" }
        }
        $installDir = Split-Path $Marker
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        $installedScript = Join-Path $installDir 'v6only.ps1'
        if ($PSCommandPath -ne $installedScript) { Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force }
        foreach ($file in @('v6core.exe','wintun.dll')) {
            if ($PSScriptRoot -ne $installDir) { Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $installDir $file) -Force }
        }
        & icacls $installDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot secure the SYSTEM task installation directory.' }
        # 计划任务：开机 + 每 5 分钟自愈（错过的开机触发由循环触发补上）
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScript`" -Watch"
        $trigger = @(
            New-ScheduledTaskTrigger -AtLogon
            New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
        )
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                         -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'v6only-watch' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Enable-ScheduledTask -TaskName 'v6only-watch' | Out-Null
        Start-ScheduledTask -TaskName 'v6only-watch'
        Write-Host "✅ 计划任务 v6only-watch 已注册（开机自启 + 5 分钟自愈）"
    }
    $Uninstall {
        Stop-V6Task
        Unregister-ScheduledTask -TaskName 'v6only-watch' -Confirm:$false -ErrorAction SilentlyContinue
        Get-V6FirewallRule -DisplayName 'v6only-block-external-dns*' -ErrorAction SilentlyContinue |
            Remove-V6FirewallRule
        Invoke-V6Off -Automatic
        Remove-Item "$env:ProgramData\v6only" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✅ v6only 已卸载并还原网络"
    }
    $Watch {
        # 守护主循环（SYSTEM 计划任务运行）
        Write-Log "v6-watch started (pid=$PID)"
        while ($true) {
            try {
                $campus, $why = Test-CampusNetwork
                if (-not $campus -and ((Test-Path $Marker) -or (Test-Path $Snapshot))) {
                    Invoke-V6Off -Automatic
                } elseif ($campus -and -not (Test-Suspended $SuspendFlg)) {
                    if ((Test-Path $Marker) -and -not (Test-CoreActive)) {
                        Invoke-V6Off
                        '' | Set-Content $SuspendFlg -Encoding UTF8
                        Write-Log 'Forwarding core lost; restored system network and paused'
                    } else { Invoke-V6On }
                }
                Start-Sleep -Seconds 20
            } catch {
                Write-Log "configuration failed: $_"
                Start-Sleep -Seconds 300
            }
        }
    }
    default {
        Write-Host "v6only for Windows — 用法:"
        Write-Host "  .\v6only.ps1 -On        应用 v6 优先配置（需管理员）"
        Write-Host "  .\v6only.ps1 -Off       回滚并挂起守护 30 分钟"
        Write-Host "  .\v6only.ps1 -Test      生效性验证"
        Write-Host "  .\v6only.ps1 -Install   注册开机自启（SYSTEM 计划任务）"
        Write-Host "  .\v6only.ps1 -Uninstall 卸载"
        Write-Host "  .\v6only.ps1 -Watch     前台守护循环（一般由计划任务调用）"
    }
}
