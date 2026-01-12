param(
  [Parameter(Mandatory=$true)][string]$DcIp
)

$ErrorActionPreference = "Stop"

Start-Transcript -Path "C:\Windows\Temp\iis-config.log" -Append

Write-Host "==> Installing IIS"
Install-WindowsFeature Web-Server -IncludeManagementTools

New-Item C:\inetpub\wwwroot\index.html -Force -Value "<h1>IIS AD Lab Server (HTTPS enabled)</h1>"

Write-Host "==> Setting DNS to DC ($DcIp)"
try {
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $DcIp
} catch {
  $if = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1).Name
  Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $DcIp
}