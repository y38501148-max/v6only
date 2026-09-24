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
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17890/health' -TimeoutSec 2
        $tun = Get-NetAdapter -Name 'v6only-tun' -ErrorAction Stop
        $routes = @(Get-NetRoute -InterfaceIndex $tun.ifIndex -ErrorAction Stop)
        return $health.policy -eq 'ipv6-before-ipv4' -and
            @($routes | Where-Object DestinationPrefix -in @('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')).Count -eq 4
    } catch { return $false }
}

function Stop-V6Core {
    if (Test-Path $CoreState) {
        $saved = Get-Content $CoreState -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.Pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq $saved.StartTicks -and $process.ProcessName -eq 'v6core') {
            Stop-Process -Id $saved.Pid -Force
            Wait-Process -Id $saved.Pid -Timeout 10 -ErrorAction SilentlyContinue
        }
    }
    # Routes belong exclusively to the named adapter owned by this program.
    $tun = Get-NetAdapter -Name 'v6only-tun' -ErrorAction SilentlyContinue
    if ($tun) { Get-NetRoute -InterfaceIndex $tun.ifIndex -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item $CoreReady,$CoreState -Force -ErrorAction SilentlyContinue
}

function Start-V6Core($Adapter) {
    if (Test-CoreActive) { return }
    foreach ($file in @('v6core.exe','wintun.dll')) {
        if (-not (Test-Path (Join-Path $CoreDir $file))) { throw "Missing release component: $file" }
    }
    Stop-V6Core
    $args = '--interface "' + $Adapter.Name + '" --device v6only-tun --dns 202.112.128.50,202.112.128.51 --ready "' + $CoreReady + '"'
    $process = Start-Process -FilePath (Join-Path $CoreDir 'v6core.exe') -ArgumentList $args -WorkingDirectory $CoreDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path (Split-Path $Marker) 'core.log') -RedirectStandardError (Join-Path (Split-Path $Marker) 'core-error.log')
    @{Pid=$process.Id;StartTicks=$process.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content $CoreState
    for ($i=0; $i -lt 40; $i++) {
        if (Test-Path $CoreReady) { break }
        if ($process.HasExited) { throw 'Forwarding core exited during start' }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path $CoreReady)) { throw 'Forwarding core readiness timeout' }
    $tun = Get-NetAdapter -Name 'v6only-tun' -ErrorAction Stop
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv4 -Dhcp Disabled
    New-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress '198.18.0.1' -PrefixLength 24 | Out-Null
    New-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress 'fd00:198:18::1' -PrefixLength 64 | Out-Null
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

function Invoke-V6On {
    $adapter = Get-ActiveAdapter
    $campus, $why = Test-CampusNetwork $adapter
    if (-not $campus) {
        if ((Test-Path $Marker) -or (Test-Path $Snapshot)) { Invoke-V6Off -Automatic }
        Write-Log 'outside campus: no configuration applied'
        return
    }
    $v6addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -match '^[23][0-9a-fA-F]{3}:' | Select-Object -First 1
    if (-not $v6addr) { Write-Log "no global IPv6 on $($adapter.Name)"; return }
    $state = if (Test-Path $Snapshot) { Get-Content $Snapshot -Raw | ConvertFrom-Json } else { $null }
    if ($state -and $state.InterfaceGuid -ne [string]$adapter.InterfaceGuid) {
        Invoke-V6Off -Automatic
        $state = $null
    }
    $current = @(Get-AdapterDns $adapter)
    $udp = Get-NetFirewallRule -DisplayName 'v6only-block-external-dns' -ErrorAction SilentlyContinue
    $tcp = Get-NetFirewallRule -DisplayName 'v6only-block-external-dns-tcp' -ErrorAction SilentlyContinue
    if ($state -and ($current -join ',') -eq ($ManagedDns -join ',') -and
        $udp.Enabled -eq 'True' -and $tcp.Enabled -eq 'True' -and (Test-Path $Marker) -and (Test-CoreActive)) {
        Remove-Item $SuspendFlg -Force -ErrorAction SilentlyContinue
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Marker) | Out-Null
    if (-not $state) {
        $guid = ([guid]$adapter.InterfaceGuid).ToString('B')
        $registry = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -ErrorAction SilentlyContinue
        $registry6 = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$guid" -ErrorAction SilentlyContinue
        $state = [pscustomobject]@{
            InterfaceGuid = [string]$adapter.InterfaceGuid
            AutomaticDns = (([string]::IsNullOrWhiteSpace($registry.NameServer) -and [string]::IsNullOrWhiteSpace($registry6.NameServer)) -or
                ((Test-Path $Marker) -and (Test-LegacyDns $current)))
            OriginalDns = $current
            AppliedDns = $ManagedDns
        }
        $state | ConvertTo-Json | Set-Content $Snapshot -Encoding UTF8
    }
    $state | Add-Member -NotePropertyName PreviousAppliedDns -NotePropertyValue @($state.AppliedDns) -Force
    $state.AppliedDns = $ManagedDns
    $state | ConvertTo-Json | Set-Content $Snapshot -Encoding UTF8
    try {
        Start-V6Core $adapter
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $ManagedDns
        foreach ($protocol in @('UDP','TCP')) {
            $name = if ($protocol -eq 'UDP') { 'v6only-block-external-dns' } else { 'v6only-block-external-dns-tcp' }
            Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block `
                -Protocol $protocol -RemotePort 53 -RemoteAddress $BlockedDnsV4 `
                -InterfaceAlias $adapter.Name -Profile Any | Out-Null
        }
        if ((@(Get-AdapterDns $adapter) -join ',') -ne ($ManagedDns -join ',')) { throw 'DNS readback mismatch' }
        New-Item -ItemType File -Force -Path $Marker | Out-Null
        Remove-Item $SuspendFlg -Force -ErrorAction SilentlyContinue
        Write-Log "campus configuration applied ($why)"
    } catch {
        Invoke-V6Off -Automatic
        throw
    }
    if (-not $Watch) { Write-Host '已应用 IPv6 优先转发；IPv6 全部失败后才回退 IPv4。' }
}

function Invoke-V6Off([switch]$Automatic) {
    if (Test-Path $Snapshot) {
        $state = Get-Content $Snapshot -Raw | ConvertFrom-Json
        $adapter = Get-NetAdapter | Where-Object { [string]$_.InterfaceGuid -eq $state.InterfaceGuid } | Select-Object -First 1
        if (-not $adapter) { throw 'Original interface is unavailable; keeping snapshot for restoration.' }
        $current = @(Get-AdapterDns $adapter) -join ','
        if ($current -eq ($state.AppliedDns -join ',') -or $current -eq ($state.PreviousAppliedDns -join ',')) {
            if ($state.AutomaticDns) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses }
            else { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($state.OriginalDns) }
        }
    } elseif (Test-Path $Marker) {
        # Legacy releases did not save a snapshot. Reset only their exact DNS profile.
        foreach ($adapter in (Get-NetAdapter)) {
            $dns = @(Get-AdapterDns $adapter)
            if (Test-LegacyDns $dns) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
            }
        }
    }
    Stop-V6Core
    Get-NetFirewallRule -DisplayName 'v6only-block-external-dns*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Remove-Item $Marker,$Snapshot -Force -ErrorAction SilentlyContinue
    if (-not $Automatic) {
        $minutes = if ($Suspend) { [int]$Suspend } else { 30 }
        New-Item -ItemType Directory -Force -Path (Split-Path $SuspendFlg) | Out-Null
        (Get-Date).AddMinutes($minutes).ToString('o') | Set-Content $SuspendFlg -Encoding UTF8
    }
    Write-Log 'campus configuration removed'
}

function Test-Suspended([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    $until = Get-Content $path -Raw
    try {
        if ((Get-Date) -ge [datetime]::Parse($until.Trim())) {
            Remove-Item $path -Force
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
        Get-NetFirewallRule -DisplayName 'v6only-block-external-dns*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule
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
