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

@'
param(
  [Parameter(Mandatory=$true)][string]$Fqdn
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\Windows\Temp\iis-cert-enroll.log' -Append

Import-Module WebAdministration

# Ensure HTTPS binding exists
if (-not (Get-WebBinding -Name 'Default Web Site' -Protocol 'https' -ErrorAction SilentlyContinue)) {
  New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*'
}

Write-Host "Requesting WebServer cert for SAN: $Fqdn"

# Request cert (machine store) using the Enterprise Web Server template
Import-Module PKI -ErrorAction SilentlyContinue

$req = Get-Certificate `
  -Template 'WebServer' `
  -DnsName $Fqdn `
  -CertStoreLocation 'Cert:\LocalMachine\My'

$thumb = $req.Certificate.Thumbprint
Write-Host "Issued cert thumbprint: $thumb"

# Bind cert to 0.0.0.0:443
$sslPath = 'IIS:\SslBindings\0.0.0.0!443'
if (Test-Path $sslPath) { Remove-Item $sslPath -Force }
New-Item $sslPath -Thumbprint $thumb -SSLFlags 0 | Out-Null

# Allow inbound 443
if (-not (Get-NetFirewallRule -DisplayName 'Allow HTTPS (Lab)' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'Allow HTTPS (Lab)' -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
}

iisreset | Out-Null
Write-Host "HTTPS configured successfully."
Stop-Transcript
'@ | Set-Content -Path $innerPath -Encoding UTF8 -Force

Write-Host "==> Creating scheduled task to enroll cert as $DomainUser"
$taskName = "Enroll-IIS-WebCert"

$sch = Join-Path $env:WINDIR "System32\schtasks.exe"

# delete if exists (ignore failures)
& $sch /Query /TN "$taskName" > $null 2> $null
if ($LASTEXITCODE -eq 0) {
  & $sch /Delete /TN "$taskName" /F > $null 2> $null
}

# Ensure inner script exists
if (-not (Test-Path $innerPath)) { throw "Inner script missing at $innerPath" }

$outLog = "C:\Windows\Temp\iis-enroll-task.out"
$errLog = "C:\Windows\Temp\iis-enroll-task.err"

# Start 2 minutes from now (schtasks requires a time even if we /Run immediately)
$st = (Get-Date).AddMinutes(2).ToString("HH:mm")

$webFqdn = "$($env:COMPUTERNAME).$DomainFqdn"
Write-Host "==> Will request certificate for: $webFqdn"

# /TR: set working dir + run script + pass fqdn param + capture stdout/stderr
$tr = "cmd.exe /c cd /d C:\Windows\Temp ^&^& powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$innerPath`" -Fqdn `"$webFqdn`" 1>>`"$outLog`" 2>>`"$errLog`""

Write-Host "==> schtasks /Create ... (password redacted)"
& $sch /Create /TN "$taskName" /SC ONCE /ST $st /RL HIGHEST /RU "$DomainUser" /RP "$DomainPassword" /TR "$tr" /F | Out-Null

& $sch /Run /TN "$taskName" | Out-Null

Write-Host "==> Waiting for enrollment task completion"
$deadline = (Get-Date).AddMinutes(45)

while ((Get-Date) -lt $deadline) {
  $q = & $sch /Query /TN "$taskName" /FO LIST /V 2>&1

  $statusLine = ($q | Select-String -Pattern '^Status:\s+').ToString()
  $resultLine = ($q | Select-String -Pattern '^(Last Result|Last Run Result):\s+').ToString()

  if ($statusLine -match 'Status:\s+Running') {
    Start-Sleep 10
    continue
  }

  Write-Host $statusLine
  Write-Host $resultLine

  $raw = ($resultLine -replace '^(Last Result|Last Run Result):\s+','').Trim()

  # normalize: accept 0, 0x0, or decimal 0
  if ($raw -eq '0' -or $raw -eq '0x0') {
    Write-Host "Enrollment task succeeded."
    Stop-Transcript
    exit 0
  }

  # If it returns decimal (like -196608), print hex for easier debugging
  try {
    $n = [int]$raw
    $hex = ('0x{0:X8}' -f ($n -band 0xFFFFFFFF))
    Write-Host "Last Result (hex): $hex"
  } catch {}

  if (Test-Path $outLog) { Get-Content $outLog -Tail 200 }
  if (Test-Path $errLog) { Get-Content $errLog -Tail 200 }
  throw "Enrollment task failed: $raw. Check C:\Windows\Temp\iis-cert-enroll.log"
}

throw "Timed out waiting for enrollment task. Check C:\Windows\Temp\iis-cert-enroll.log"