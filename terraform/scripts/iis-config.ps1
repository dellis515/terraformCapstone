param(
  [Parameter(Mandatory=$true)][string]$DomainFqdn,
  [Parameter(Mandatory=$true)][string]$DcIp,
  [Parameter(Mandatory=$true)][string]$DomainUser,       # e.g. DELLIS\Administrator
  [Parameter(Mandatory=$true)][string]$DomainPassword,   # passed via protected_settings
  [Parameter(Mandatory=$true)][string]$CaCommonName      # e.g. dellislab-CA01
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

Write-Host "==> Waiting for domain join + AD readiness"
$deadline = (Get-Date).AddMinutes(45)
while ((Get-Date) -lt $deadline) {
  try {
    Resolve-DnsName $DomainFqdn -ErrorAction Stop | Out-Null

    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { throw "Not domain-joined yet" }

    if (Test-Path "\\$DcIp\SYSVOL") { break }

    Write-Host "Domain joined; waiting for SYSVOL..."
  } catch {
    Write-Host "Not ready: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 15
}

if ((Get-Date) -ge $deadline) {
  Write-Error "Timed out waiting for domain readiness."
  Stop-Transcript
  exit 1
}

Write-Host "==> Waiting for CA to publish into AD ($CaCommonName)"
$deadline = (Get-Date).AddMinutes(60)
while ((Get-Date) -lt $deadline) {
  try {
    $adca = & certutil.exe -adca 2>$null
    if ($adca -and ($adca -match [regex]::Escape($CaCommonName))) {
      Write-Host "CA appears in AD."
      break
    }
    Write-Host "CA not visible yet..."
  } catch {
    Write-Host "certutil -adca failed: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 15
}

if ((Get-Date) -ge $deadline) {
  Write-Error "Timed out waiting for CA to appear in AD."
  Stop-Transcript
  exit 1
}

# Inner script that runs as Domain Admin to guarantee enrollment works with default template permissions
$innerPath = "C:\Windows\Temp\request-webcert.ps1"
@"
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\Windows\Temp\iis-cert-enroll.log' -Append

Import-Module WebAdministration

# Ensure HTTPS binding exists
if (-not (Get-WebBinding -Name 'Default Web Site' -Protocol 'https' -ErrorAction SilentlyContinue)) {
  New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*'
}

# Request cert (machine store) using the Enterprise Web Server template
Import-Module PKI -ErrorAction SilentlyContinue

`$fqdn = "dellis.lab"
Write-Host "Requesting WebServer cert for SAN: `$fqdn"

`$req = Get-Certificate `
  -Template 'WebServer' `
  -DnsName `$fqdn `
  -CertStoreLocation 'Cert:\LocalMachine\My'

`$thumb = `$req.Certificate.Thumbprint
Write-Host "Issued cert thumbprint: `$thumb"

# Bind cert to 0.0.0.0:443
`$sslPath = 'IIS:\SslBindings\0.0.0.0!443'
if (Test-Path `$sslPath) { Remove-Item `$sslPath -Force }
New-Item `$sslPath -Thumbprint `$thumb -SSLFlags 0 | Out-Null

# Allow inbound 443
if (-not (Get-NetFirewallRule -DisplayName 'Allow HTTPS (Lab)' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'Allow HTTPS (Lab)' -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
}

iisreset | Out-Null
Write-Host "HTTPS configured successfully."

Stop-Transcript
"@ | Set-Content -Path $innerPath -Encoding UTF8 -Force

Write-Host "==> Creating scheduled task to enroll cert as $DomainUser"
$taskName = "Enroll-IIS-WebCert"

schtasks.exe /Delete /TN $taskName /F | Out-Null 2>&1

# Start 1 minute from now
$st = (Get-Date).AddMinutes(1).ToString("HH:mm")
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

schtasks.exe /Run /TN $taskName | Out-Null

Write-Host "==> Waiting for enrollment task completion"
$deadline = (Get-Date).AddMinutes(45)
while ((Get-Date) -lt $deadline) {
  $q = schtasks.exe /Query /TN $taskName /V /FO LIST 2>$null
  if ($LASTEXITCODE -eq 0) {
    $line = ($q | Select-String -Pattern "^Last Run Result:\s+").Line
    if ($line) {
      $result = $line -replace "^Last Run Result:\s+", ""
      if ($result -eq "0x0") {
        Write-Host "Enrollment task succeeded."
        Stop-Transcript
        exit 0
      }
      if ($result -ne "0x41301") { # 0x41301 = running
        Write-Error "Enrollment task failed: $result. Check C:\Windows\Temp\iis-cert-enroll.log"
        Stop-Transcript
        exit 1
      }
    }
  }
  Start-Sleep -Seconds 15
}

Write-Error "Timed out waiting for enrollment task. Check C:\Windows\Temp\iis-cert-enroll.log"
Stop-Transcript
exit 1
