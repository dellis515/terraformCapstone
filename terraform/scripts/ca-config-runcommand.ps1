param(
  [string]$DcIp = "10.0.0.4",
  [string]$CaCommonName = "DELLISLAB-CA01"
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path "C:\Windows\Temp\ca-configure.log" -Append
$ProgressPreference = "SilentlyContinue"
$ConfirmPreference  = "None"

Write-Host "==> Ensuring DNS points to DC ($DcIp)"
try {
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $DcIp
} catch {
  $if = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1).Name
  Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $DcIp
}

Write-Host "==> Waiting for domain secure channel"
$domainFqdn = (Get-CimInstance Win32_ComputerSystem).Domain
$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
  $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c","nltest /sc_verify:$domainFqdn" -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -eq 0) { break }
  Start-Sleep -Seconds 15
}
if ((Get-Date) -ge $deadline) { throw "Secure channel not ready (nltest sc_verify failed)." }

Write-Host "==> Installing ADCS role"
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null

Write-Host "==> Configuring Enterprise Root CA (idempotent)"
$cfgKey = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
if (Test-Path $cfgKey) {
  Write-Host "CA already configured (CertSvc\\Configuration exists). Skipping CA install."
} else {
  Import-Module ADCSDeployment
  Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCA `
    -CACommonName $CaCommonName `
    -KeyLength 2048 `
    -HashAlgorithmName SHA256 `
    -ValidityPeriod Years `
    -ValidityPeriodUnits 10 `
    -Force
}

Write-Host "==> Optional: Web Enrollment"
Install-WindowsFeature ADCS-Web-Enrollment -IncludeManagementTools | Out-Null
try {
  Install-AdcsWebEnrollment -Force
} catch {
  Write-Host "Web Enrollment may already be configured: $($_.Exception.Message)"
}

Write-Host "==> Ensure CertSvc is running"
Set-Service -Name CertSvc -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name CertSvc -ErrorAction SilentlyContinue

Write-Host "==> Add WebServer template to issuance list (force)"
& certutil.exe -f -SetCATemplates +WebServer | Out-Null

Write-Host "==> Enable computer auto-enrollment GPO (no ActiveDirectory module required)"
Install-WindowsFeature GPMC -IncludeManagementTools | Out-Null
Import-Module GroupPolicy

$dn = ([ADSI]"LDAP://RootDSE").defaultNamingContext
$gpoName = "Enable Certificate Autoenrollment"

$gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $gpoName }

Set-GPRegistryValue -Name $gpoName `
  -Key "HKLM\Software\Policies\Microsoft\Cryptography\AutoEnrollment" `
  -ValueName "AEPolicy" -Type DWord -Value 7

New-GPLink -Name $gpoName -Target $dn -Enforced Yes -ErrorAction SilentlyContinue

Write-Host "==> CA config complete"
Stop-Transcript
