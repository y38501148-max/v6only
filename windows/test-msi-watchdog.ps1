param([string]$Out)
# Recovery guard for the disposable CI VM only; never included in the installer.
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){exit 1}
$deadline=(Get-Date).AddMinutes(5)
while((Get-Date) -lt $deadline){if(Test-Path "$Out/watchdog.done"){exit};Start-Sleep 2}
New-Item -ItemType File "$Out/watchdog-restored.flag" -Force|Out-Null
Remove-Item "$env:ProgramData/v6only/enabled.flag" -Force -ErrorAction SilentlyContinue
& sc.exe stop V6Only | Out-File "$Out/watchdog.log"
Get-Process v6core -ErrorAction SilentlyContinue|Stop-Process -Force
$tun=Get-NetAdapter -Name 'v6only-tun' -ErrorAction SilentlyContinue
if($tun){Get-NetRoute -InterfaceIndex $tun.ifIndex -ErrorAction SilentlyContinue|Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue}
Get-Content "$Out/baseline.json" -Raw|ConvertFrom-Json|Group-Object InterfaceIndex|ForEach-Object {
 $addresses=@($_.Group.ServerAddresses|Select-Object -Unique)
 if($addresses){Set-DnsClientServerAddress -InterfaceIndex ([int]$_.Name) -ServerAddresses $addresses}
 else{Set-DnsClientServerAddress -InterfaceIndex ([int]$_.Name) -ResetServerAddresses}
}
Copy-Item "$env:ProgramData/v6only/*.log" $Out -ErrorAction SilentlyContinue
