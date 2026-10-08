param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # Elevate only the fixed installer, not the entire desktop application.
        # EncodedCommand keeps spaces, quotes and non-ASCII install paths intact.
        $quoted = $PSCommandPath.Replace("'", "''")
        $command = "& '$quoted'; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $child = Start-Process -FilePath "$PSHOME/powershell.exe" -Verb RunAs -Wait -PassThru `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        if ($child.ExitCode -ne 0) { throw "后台服务配置失败（退出码 $($child.ExitCode)），请查看系统服务或重新安装 MSI。" }
        exit 0
    }

    $binary = Join-Path (Split-Path $PSScriptRoot) 'v6service.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw '后台服务文件缺失，请使用完整的 V6Only MSI 安装包修复安装。'
    }
    $service = Get-Service -Name V6Only -ErrorAction SilentlyContinue
    if (-not $service) {
        $service = New-Service -Name V6Only -DisplayName V6Only `
            -BinaryPathName ('"' + $binary + '"') -StartupType Automatic `
            -Description 'V6Only network routing and traffic records'
    } else {
        Set-Service -Name V6Only -StartupType Automatic
    }
    if ($service.Status -eq 'StopPending') {
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(90))
    }
    Start-Service -Name V6Only
    $service = Get-Service -Name V6Only
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
    Write-Output 'V6Only service is running'
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
