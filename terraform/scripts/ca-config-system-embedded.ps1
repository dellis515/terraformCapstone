param(
  [Parameter(Mandatory=$true)][string]$DcIp,
  [Parameter(Mandatory=$true)][string]$DomainUser,       # recommend UPN: labadmin@dellis.lab
  [Parameter(Mandatory=$true)][string]$DomainPassword,
  [Parameter(Mandatory=$true)][string]$CaCommonName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ConfirmPreference  = "None"

Start-Transcript -Path "C:\Windows\Temp\ca-bootstrap.log" -Append

function Set-DnsToDc {
  param([string]$Ip)
  try {
    Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $Ip
  } catch {
    $if = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1).Name
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $Ip
  }
}

Write-Host "==> Ensuring DNS points to DC ($DcIp)"
Set-DnsToDc -Ip $DcIp

Write-Host "==> Ensuring Secondary Logon (seclogon) is available"
Set-Service seclogon -StartupType Manual
Start-Service seclogon

Write-Host "==> Waiting for domain secure channel"
$dom = (Get-CimInstance Win32_ComputerSystem).Domain
$deadline = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $deadline) {
  cmd /c "nltest /sc_verify:$dom" | Out-Null
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep -Seconds 15
}
if ((Get-Date) -ge $deadline) {
  throw "Secure channel not ready (nltest /sc_verify:$dom failed)."
}

# -------------------------
# Embedded CA configuration script content (runs as DomainUser)
# -------------------------
$innerPath = "C:\Windows\Temp\ca-config-inner.ps1"

@'
param(
  [Parameter(Mandatory=$true)][string]$DcIp,
  [Parameter(Mandatory=$true)][string]$CaCommonName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ConfirmPreference  = "None"

Start-Transcript -Path "C:\Windows\Temp\ca-configure.log" -Append

function Set-DnsToDc {
  param([string]$Ip)
  try {
    Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $Ip
  } catch {
    $if = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1).Name
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $Ip
  }
}

Write-Host "==> Ensuring DNS points to DC ($DcIp)"
Set-DnsToDc -Ip $DcIp

Write-Host "==> Verifying secure channel"
$dom = (Get-CimInstance Win32_ComputerSystem).Domain
cmd /c "nltest /sc_verify:$dom"
if ($LASTEXITCODE -ne 0) { throw "Secure channel verification failed." }

Write-Host "==> Installing ADCS role"
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null

Write-Host "==> Configuring Enterprise Root CA (idempotent)"
$cfgKey = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
if (Test-Path $cfgKey) {
  Write-Host "CA already configured (CertSvc\Configuration exists). Skipping Install-AdcsCertificationAuthority."
} else {
  # Helpful pre-check: show whether token includes Enterprise Admins (common cause of ERROR_DS_RANGE_CONSTRAINT)
  try {
    $ea = (whoami /groups) -join "`n"
    if ($ea -notmatch "Enterprise Admins") {
      Write-Host "WARNING: Current token does not show 'Enterprise Admins'. Enterprise CA install may fail unless account has rights."
    }
  } catch {}

  Import-Module ADCSDeployment
  try {
    Install-AdcsCertificationAuthority `
      -CAType EnterpriseRootCA `
      -CACommonName $CaCommonName `
      -KeyLength 2048 `
      -HashAlgorithmName SHA256 `
      -ValidityPeriod Years `
      -ValidityPeriodUnits 10 `
      -Force
  } catch {
    Write-Host "Install-AdcsCertificationAuthority failed: $($_.Exception.Message)"
    throw
  }
}

Write-Host "==> Optional: Web Enrollment"
Install-WindowsFeature ADCS-Web-Enrollment -IncludeManagementTools | Out-Null
try { Install-AdcsWebEnrollment -Force } catch { Write-Host "Web Enrollment may already be configured: $($_.Exception.Message)" }

Write-Host "==> Ensure CertSvc is running"
Set-Service -Name CertSvc -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name CertSvc -ErrorAction SilentlyContinue
Get-Service CertSvc -ErrorAction SilentlyContinue | Format-List Name,Status,StartType

Write-Host "==> Publish WebServer template to CA issuance list"
& certutil.exe -f -SetCATemplates +WebServer | Out-Null

Write-Host "==> Enable computer auto-enrollment GPO (no ActiveDirectory module required)"
Install-WindowsFeature GPMC -IncludeManagementTools | Out-Null
Import-Module GroupPolicy

# RootDSE defaultNamingContext is a PropertyValueCollection; grab the first value
$dn = [string]([ADSI]"LDAP://RootDSE").defaultNamingContext

$gpoName = "Enable Certificate Autoenrollment"
$gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $gpoName }

Set-GPRegistryValue -Name $gpoName `
  -Key "HKLM\Software\Policies\Microsoft\Cryptography\AutoEnrollment" `
  -ValueName "AEPolicy" -Type DWord -Value 7

New-GPLink -Name $gpoName -Target $dn -Enforced Yes -ErrorAction SilentlyContinue

Write-Host "==> CA configuration complete"
Stop-Transcript
'@ | Set-Content -Path $innerPath -Encoding UTF8 -Force

# Spawn embedded script as domain admin (no scheduled task, no handler RunAsUser)
Write-Host "==> Launching embedded CA config as $DomainUser"
$sec  = ConvertTo-SecureString $DomainPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($DomainUser, $sec)

$out = "C:\Windows\Temp\ca-inner.out"
$err = "C:\Windows\Temp\ca-inner.err"

$p = Start-Process powershell.exe -Credential $cred -Wait -PassThru -NoNewWindow -ArgumentList @(
  "-ExecutionPolicy","Bypass","-NoProfile",
  "-File",$innerPath,
  "-DcIp",$DcIp,
  "-CaCommonName",$CaCommonName
) -RedirectStandardOutput $out -RedirectStandardError $err

Write-Host "==> Embedded CA script exit code: $($p.ExitCode)"
if ($p.ExitCode -ne 0) {
  Write-Host "---- STDOUT (tail) ----"
  Get-Content $out -Tail 200 -ErrorAction SilentlyContinue
  Write-Host "---- STDERR (tail) ----"
  Get-Content $err -Tail 200 -ErrorAction SilentlyContinue
  throw "Embedded CA config failed. See C:\Windows\Temp\ca-configure.log and $out / $err"
}

Stop-Transcript
