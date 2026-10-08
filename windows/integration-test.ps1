# Actual Wintun tests, strictly restricted to disposable GitHub-hosted Windows VMs.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Refusing to change networking outside a disposable GitHub-hosted Windows VM.'
}
& "$PSScriptRoot/build.ps1"
$bin = Join-Path $PSScriptRoot '../core/build/integration'
New-Item -ItemType Directory -Force $bin | Out-Null
Push-Location (Join-Path $PSScriptRoot '../core')
try {
    foreach ($command in @('netfixture','netcheck')) {
        go build -o "$bin/$command.exe" "./cmd/$command"
        if ($LASTEXITCODE) { throw "Build failed: $command" }
    }
} finally { Pop-Location }
$ready = Join-Path $bin 'ready.json'
$core = $null; $fixture = $null
$physical = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
$adapter = Get-NetAdapter -InterfaceIndex $physical.InterfaceIndex
function Stop-Core {
    if ($script:core -and -not $script:core.HasExited) { $script:core | Stop-Process -Force; $script:core.WaitForExit() }
    $script:core = $null
    Remove-Item $ready -Force -ErrorAction SilentlyContinue
    $tun = Get-NetAdapter -Name 'v6only-ci' -ErrorAction SilentlyContinue
    if ($tun) { Get-NetRoute -InterfaceIndex $tun.ifIndex -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }
}
function Start-Core([string]$Dns, [bool]$Fake) {
    $arguments = "--interface `"$($adapter.Name)`" --device v6only-ci --dns `"$Dns`" --ready `"$ready`""
    if ($Fake) { $arguments += ' --fake-dns' }
    $script:core = Start-Process "$PSScriptRoot/v6core.exe" -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -PassThru `
        -RedirectStandardOutput "$bin/core.log" -RedirectStandardError "$bin/core-error.log"
    for ($i=0;$i -lt 80;$i++) {
        if (Test-Path $ready) { break }
        if ($script:core.HasExited) { throw (Get-Content "$bin/core-error.log" -Raw) }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path $ready)) { throw 'Core readiness timeout' }
    $tun=$null
    for($attempt=0;$attempt -lt 40;$attempt++){
        try{$tun=Get-NetAdapter -Name 'v6only-ci' -ErrorAction Stop;break}catch{Start-Sleep -Milliseconds 250}
    }
    if(!$tun){throw 'Forwarding adapter not registered after driver start'}
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv4 -Dhcp Disabled
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv4 -DadTransmits 0
    Set-NetIPInterface -InterfaceIndex $tun.ifIndex -AddressFamily IPv6 -DadTransmits 0
    foreach ($ip in @('198.18.0.1','fd00:198:18::1')) {
        if (-not (Get-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue)) {
            $prefix = if ($ip -like '*:*') {64} else {24}
            New-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress $ip -PrefixLength $prefix | Out-Null
        }
    }
    for ($i=0;$i -lt 40;$i++) {
        if ((Get-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress '198.18.0.1').AddressState -eq 'Preferred') { break }
        Start-Sleep -Milliseconds 250
    }
    if ((Get-NetIPAddress -InterfaceIndex $tun.ifIndex -IPAddress '198.18.0.1').AddressState -ne 'Preferred') { throw 'Wintun address not ready' }
    return $tun
}
try {
    $fixture=Start-Process "$bin/netfixture.exe" -ArgumentList '--listen4 127.0.0.1 --listen6 ::1 --v4 127.0.0.1 --v6 ::1' -PassThru `
        -RedirectStandardOutput "$bin/fixture.log" -RedirectStandardError "$bin/fixture-error.log"
    $tun=Start-Core '127.0.0.1:15353' $true
    New-NetRoute -InterfaceIndex $tun.ifIndex -DestinationPrefix '198.18.0.0/15' -NextHop '0.0.0.0' -PolicyStore ActiveStore | Out-Null
    & "$bin/netcheck.exe" --skip-sni
    if ($LASTEXITCODE) { throw 'Controlled Wintun integration failed' }
    Stop-Core
    Write-Host 'PASS actual Wintun dual-stack DNS/TCP/UDP'

    $dns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses | Select-Object -First 1
    if (-not $dns) { throw 'No physical DNS for full-routing test' }
    & curl.exe --noproxy '*' -fsS --max-time 20 http://1.1.1.1/ -o NUL
    if ($LASTEXITCODE) { throw 'Baseline HTTPS failed' }
    $tun=Start-Core $dns $false
    foreach ($prefix in @('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')) {
        $hop=if($prefix -like '*:*'){'::'}else{'0.0.0.0'}
        New-NetRoute -InterfaceIndex $tun.ifIndex -DestinationPrefix $prefix -NextHop $hop -PolicyStore ActiveStore -RouteMetric 1 | Out-Null
    }
    & curl.exe --noproxy '*' -fsS --max-time 30 http://1.1.1.1/ -o NUL
    if ($LASTEXITCODE) { throw 'HTTPS failed under full Wintun routing' }
    Stop-Core
    & curl.exe --noproxy '*' -fsS --max-time 20 http://1.1.1.1/ -o NUL
    if ($LASTEXITCODE) { throw 'HTTPS failed after core exit' }
    Write-Host 'PASS full routing and physical network recovery after core exit'
} finally {
    Stop-Core
    if($fixture -and -not $fixture.HasExited){$fixture | Stop-Process -Force}
    Get-Content "$bin/core.log","$bin/core-error.log","$bin/fixture-error.log" -ErrorAction SilentlyContinue
}
