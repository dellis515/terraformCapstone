param(
  [Parameter(Mandatory=$true)][string]$DomainFqdn,
  [Parameter(Mandatory=$true)][string]$DcIp,
  [Parameter(Mandatory=$true)][string]$DomainUser,       # e.g. DELLIS\Administrator
  [Parameter(Mandatory=$true)][string]$DomainPassword,   # plain text passed via protected_settings
  [Parameter(Mandatory=$true)][string]$CaCommonName      # e.g. dellislab-CA01
)

$ErrorActionPreference = "Stop"

$log = "C:\Windows\Temp\ca-bootstrap.log"
Start-Transcript -Path $log -Append

Write-Host "==> Setting DNS to DC ($DcIp)"
try {
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $DcIp
} catch {
  # Some NICs aren't named Ethernet; fallback
  $if = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1).Name
  Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $DcIp
}

# Inner script that must run with domain credentials (Enterprise/Domain Admin)
$innerPath = "C:\Windows\Temp\configure-adcs.ps1"
@"
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\Windows\Temp\ca-configure.log' -Append

Write-Host '==> Installing ADCS role'
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools

Write-Host '==> Configuring Enterprise Root CA'
Import-Module ADCSDeployment

Install-AdcsCertificationAuthority `
  -CAType EnterpriseRootCA `
  -CACommonName '$CaCommonName' `
  -KeyLength 2048 `
  -HashAlgorithmName SHA256 `
  -ValidityPeriod Years `
  -ValidityPeriodUnits 10 `
  -Force

Write-Host '==> Optional: Web Enrollment'
Install-WindowsFeature ADCS-Web-Enrollment -IncludeManagementTools
Install-AdcsWebEnrollment -Force

Write-Host '==> Publishing common templates (Web Server)'
# Adds WebServer template to the CA's issuance list (harmless if already present)
certutil -f -SetCATemplates +WebServer | Out-Null

Write-Host '==> Enabling Computer certificate autoenrollment via GPO'
Install-WindowsFeature GPMC -IncludeManagementTools | Out-Null
Import-Module GroupPolicy
Import-Module ActiveDirectory

`$gpoName = 'Enable Certificate Autoenrollment'
`$dn = (Get-ADDomain).DistinguishedName

`$gpo = Get-GPO -Name `$gpoName -ErrorAction SilentlyContinue
if (-not `$gpo) { `$gpo = New-GPO -Name `$gpoName }

# AEPolicy=7 => enroll + renew + update (Computer side)
Set-GPRegistryValue -Name `$gpoName `
  -Key 'HKLM\Software\Policies\Microsoft\Cryptography\AutoEnrollment' `
  -ValueName 'AEPolicy' -Type DWord -Value 7

New-GPLink -Name `$gpoName -Target `$dn -Enforced Yes -ErrorAction SilentlyContinue

Write-Host '==> Done'
Stop-Transcript
"@ | Set-Content -Path $innerPath -Encoding UTF8 -Force

Write-Host "==> Creating scheduled task to run CA configuration as $DomainUser"
$taskName = "Configure-ADCS-EnterpriseCA"

# Schedule 1 minute in the future to avoid time parsing edge cases
$start = (Get-Date).AddMinutes(1)
$st = $start.ToString("HH:mm")

# Create / replace task
schtasks.exe /Delete /TN $taskName /F | Out-Null 2>&1

$tr = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$innerPath`""
schtasks.exe /Create `
  /TN $taskName `
  /SC ONCE `
  /ST $st `
  /RL HIGHEST `
  /RU $DomainUser `
  /RP $DomainPassword `
  /TR $tr `
  /F | Out-Null

Write-Host "==> Running scheduled task"
schtasks.exe /Run /TN $taskName | Out-Null

Write-Host "==> Waiting for scheduled task completion"
$maxWaitMin = 60
$endWait = (Get-Date).AddMinutes($maxWaitMin)

while ((Get-Date) -lt $endWait) {
  $q = schtasks.exe /Query /TN $taskName /V /FO LIST 2>$null
  if ($LASTEXITCODE -ne 0) { Start-Sleep -Seconds 10; continue }

  $lastResultLine = ($q | Select-String -Pattern "^Last Run Result:\s+").Line
  if ($lastResultLine) {
    $result = $lastResultLine -replace "^Last Run Result:\s+", ""
    # 0x0 means success
    if ($result -eq "0x0") {
      Write-Host "Task succeeded."
      Stop-Transcript
      exit 0
    }
    # If it's still running, it often shows 0x41301
    if ($result -ne "0x41301") {
      Write-Error "Task finished with non-success result: $result. Check C:\Windows\Temp\ca-configure.log"
      Stop-Transcript
      exit 1
    }
  }

  Start-Sleep -Seconds 15
}

Write-Error "Timed out waiting for CA configuration task after $maxWaitMin minutes. Check logs in C:\Windows\Temp\."
Stop-Transcript
exit 1
