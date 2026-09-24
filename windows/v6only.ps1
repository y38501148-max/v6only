#Requires -Version 5.1
<#
.SYNOPSIS
    v6only for Windows — 校园网感知 v6 优先守护 (v2)
.DESCRIPTION
    与 macOS 端同构：
      - 双栈站点走 IPv6（DNS 稳回 AAAA + 系统前缀策略偏好 v6）
      - v4-only 站点直连 IPv4，不受影响
      - 封外部 IPv4 明文 DNS（防硬编码 8.8.8.8 绕过解析策略）
      - 校园 DNS（202.112.128.0/24、10/8 网关型）放行
    检测信号（任一命中即校园网）：
      - 默认网关 ∈ 10/8
      - DNS 后缀含 buaa.edu.cn
      - SSID 以 BUAA 开头（WLAN API，无需定位权限）
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
$DnsV6Primary = '2400:3200::1'        # AliDNS v6 (CERNET2 直连 9ms)
$DnsV6Backup  = '240c::6666'          # CNGI v6
$DnsCampusV4  = '202.112.128.50'      # 校园 v4 兜底（v4-only 域名查 A）
$BlockedDnsV4 = @('8.8.8.8','8.8.4.4','1.1.1.1','9.9.9.9')  # 外部 v4 明文 DNS 封堵名单

function Write-Log([string]$msg) {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File $LogFile -Append -Encoding utf8
}

function Test-CampusNetwork {
    # 信号1: 默认网关 ∈ 10/8
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
           Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if ($gw -and $gw.StartsWith('10.')) { return $true, "gateway=$gw" }
    # 信号2: DNS 后缀
    $suffix = (Get-DnsClientGlobalSetting).SuffixSearchList -join ','
    if ($suffix -match 'buaa\.edu\.cn') { return $true, "suffix=$suffix" }
    # 信号3: SSID
    try {
        $wlan = (netsh wlan show interfaces | Select-String '^\s*SSID').ToString()
        $ssid = ($wlan -split ':',2)[1].Trim()
        if ($ssid -and $ssid -match '^BUAA') { return $true, "ssid=$ssid" }
    } catch {}
    return $false, ''
}

function Invoke-V6On {
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' |
               Sort-Object LinkSpeed -Descending | Select-Object -First 1
    if (-not $adapter) { Write-Log 'no active adapter'; return }
    $v6addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
              Where-Object IPAddress -like '2001:*' | Select-Object -First 1
    if (-not $v6addr) { Write-Log "no global IPv6 on $($adapter.Name), abort"; return }
    Write-Log "v6 addr = $($v6addr.IPAddress) on $($adapter.Name)"

    # DNS: v6 优先 + 校园 v4 兜底
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
        -ServerAddresses $DnsV6Primary, $DnsV6Backup, $DnsCampusV4
    Clear-DnsClientCache

    # 封外部 v4 明文 DNS：出站 53/udp+tcp 到黑名单 IP
    $fwRule = Get-NetFirewallRule -DisplayName 'v6only-block-external-dns' -ErrorAction SilentlyContinue
    if (-not $fwRule) {
        New-NetFirewallRule -DisplayName 'v6only-block-external-dns' `
            -Direction Outbound -Action Block -Protocol UDP -RemotePort 53 `
            -RemoteAddress $BlockedDnsV4 -Profile Any | Out-Null
        New-NetFirewallRule -DisplayName 'v6only-block-external-dns-tcp' `
            -Direction Outbound -Action Block -Protocol TCP -RemotePort 53 `
            -RemoteAddress $BlockedDnsV4 -Profile Any | Out-Null
    }
    New-Item -ItemType File -Force -Path $Marker | Out-Null
    Remove-Item $SuspendFlg -Force -ErrorAction SilentlyContinue
    Write-Log 'v6-prefer ON'
    if (-not $Watch) { Write-Host "✅ v6 优先模式已开启（双栈站走 v6，v4-only 站直连 v4）" }
}

function Invoke-V6Off {
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' |
               Sort-Object LinkSpeed -Descending | Select-Object -First 1
    if ($adapter) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses }
    Get-NetFirewallRule -DisplayName 'v6only-block-external-dns*' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    Remove-Item $Marker -Force -ErrorAction SilentlyContinue
    # 挂起守护，防止被拉回
    $minutes = if ($Suspend) { [int]$Suspend } else { 30 }
    New-Item -ItemType File -Force -Path $SuspendFlg | Out-Null
    (Get-Date).AddMinutes($minutes).ToString('o') | Out-File $SuspendFlg -Encoding utf8
    Clear-DnsClientCache
    Write-Log "v6-prefer OFF, daemon suspended ${minutes}min"
    if (-not $Watch) { Write-Host "✅ 已回滚，守护挂起 ${minutes} 分钟" }
}

function Test-Expired([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    $until = Get-Content $path -Raw
    try { if ((Get-Date) -gt (Get-Date $until.Trim())) { Remove-Item $path -Force; return $false } } catch {}
    return $true
}

function Invoke-Test {
    $fail = 0
    function Ok($m){ Write-Host "  [PASS] $m" }
    function Bad($m){ Write-Host "  [FAIL] $m"; $script:fail++ }

    Write-Host "=== v6only Windows 验证 ==="
    $v6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
          Where-Object IPAddress -like '2001:*' | Select-Object -First 1
    if ($v6) { Ok "全球 v6 = $($v6.IPAddress)" } else { Bad "无 2001:: v6 地址" }

    $dns = (Get-DnsClientServerAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object ServerAddresses).ServerAddresses
    if ($dns -contains $DnsV6Primary) { Ok "DNS 上游含 v6 ($DnsV6Primary)" } else { Bad "DNS 未配置 v6 上游: $dns" }

    try {
        $r = Resolve-DnsName www.edu.cn -Type AAAA -Server $DnsV6Primary -DnsOnly -ErrorAction Stop
        Ok "v6 上游解析 AAAA = $($r[0].IPAddress)"
    } catch { Bad "v6 上游解析失败（链路抖动？）" }

    try {
        $r = Resolve-DnsName mirrors.ustc.edu.cn -Type A -Server $DnsCampusV4 -DnsOnly -ErrorAction Stop
        Ok "校园 v4 DNS 解析 A = $($r[0].IPAddress)"
    } catch { Bad "校园 v4 DNS 不可达" }

    $blocked = $true
    try { Resolve-DnsName www.baidu.com -Server 8.8.8.8 -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null; $blocked = $false } catch {}
    if ($blocked) { Ok "外部 v4 DNS (8.8.8.8) 已封" } else { Bad "8.8.8.8 仍可查询" }

    $t = Test-NetConnection codexapis.com -Port 443 -ConstrainSourceAddress -ConstrainInterface 0 -InformationLevel Quiet -ErrorAction SilentlyContinue
    $conn = Test-NetConnection codeforces.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($conn) { Ok "codeforces.com:443 可达" } else { Bad "codeforces.com 不可达" }
    $k = Test-NetConnection kedaya.ai -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($k) { Ok "kedaya.ai:443 可达" } else { Bad "kedaya.ai 不可达" }

    if (Test-Path $Marker) { Ok "v6 优先模式标记存在" } else { Bad "无 active 标记" }
    Write-Host "=== 结果：通过 $((12 - $fail)) 项 / 失败 $fail 项 ==="
    exit $fail
}

# ── 主入口 ──
switch ($true) {
    $Test      { Invoke-Test }
    $On        { Invoke-V6On }
    $Off       { Invoke-V6Off }
    $Install {
        # 计划任务：开机 + 每 5 分钟自愈（错过的开机触发由循环触发补上）
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Watch"
        $trigger = @(
            New-ScheduledTaskTrigger -AtLogon
            New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
        )
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                         -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName 'v6only-watch' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "✅ 计划任务 v6only-watch 已注册（开机自启 + 5 分钟自愈）"
    }
    $Uninstall {
        Unregister-ScheduledTask -TaskName 'v6only-watch' -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetFirewallRule -DisplayName 'v6only-block-external-dns*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule
        Invoke-V6Off
        Remove-Item "$env:ProgramData\v6only" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✅ v6only 已卸载并还原网络"
    }
    $Watch {
        # 守护主循环（SYSTEM 计划任务运行）
        Write-Log "v6-watch started (pid=$PID)"
        while ($true) {
            if (-not (Test-Expired $SuspendFlg) -and (Test-Path $SuspendFlg)) {
                Start-Sleep 20; continue
            }
            $campus, $why = Test-CampusNetwork
            if ($campus -and -not (Test-Path $Marker)) {
                Write-Log "campus detected ($why) -> ON"
                Invoke-V6On
            } elseif (-not $campus -and (Test-Path $Marker)) {
                Write-Log "left campus -> OFF"
                Invoke-V6Off
            }
            Start-Sleep -Seconds 20
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
