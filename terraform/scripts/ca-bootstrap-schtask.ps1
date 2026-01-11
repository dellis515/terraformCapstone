param(
  [Parameter(Mandatory=$true)][string]$DomainNetbios,      # e.g. DELLIS
  [Parameter(Mandatory=$true)][string]$DomainUser,         # e.g. labadmin
  [Parameter(Mandatory=$true)][string]$DomainPassword,     # plaintext from protected settings
  [Parameter(Mandatory=$true)][string]$DomainFqdn,         # e.g. dellis.lab
  [Parameter(Mandatory=$true)][string]$DcIp,               # e.g. 10.0.0.4
  [Parameter(Mandatory=$true)][string]$ScriptPath          # e.g. .\ca-config-runcommand.ps1
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ConfirmPreference  = "None"

$bootstrapLog = "C:\Windows\Temp\ca-bootstrap.log"
Start-Transcript -Path $bootstrapLog -Append

function Set-DnsToDc([string]$Ip) {
  try { Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $Ip }
  catch {
    $if = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1).Name
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $Ip
  }
}

function Wait-DomainReady {
  param([string]$Fqdn,[string]$Netbios,[string]$User,[int]$Minutes=20)

  Write-Host "==> Waiting for domain secure channel: $Fqdn"
  $deadline = (Get-Date).AddMinutes($Minutes)

  while ((Get-Date) -lt $deadline) {
    cmd /c "nltest /sc_verify:$Fqdn" | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 15
  }
  if ((Get-Date) -ge $deadline) { throw "Secure channel not ready (nltest sc_verify failed)." }

  # Critical: ensure account name maps to SID (prevents 'No mapping between account names and security IDs')
  $acct = "$Netbios\$User"
  Write-Host "==> Verifying SID mapping for $acct"
  $deadline = (Get-Date).AddMinutes(10)
  while ((Get-Date) -lt $deadline) {
    try {
      [void]([System.Security.Principal.NTAccount]$acct).Translate([System.Security.Principal.SecurityIdentifier])
      return
    } catch {
      Start-Sleep 10
    }
  }
  throw "Account $acct did not resolve to a SID. DNS/DC reachability or join still settling."
}

Write-Host "==> Ensuring DNS points to DC ($DcIp)"
Set-DnsToDc $DcIp

Wait-DomainReady -Fqdn $DomainFqdn -Netbios $DomainNetbios -User $DomainUser

$ru = "$DomainNetbios\$DomainUser"

# optional: ensure local admin (harmless in lab)
Write-Host "==> Ensuring $ru is in local Administrators"
cmd /c "net localgroup administrators `"$ru`" /add" | Out-Null

if (-not (Test-Path $ScriptPath)) { throw "CA config script not found at $ScriptPath" }

$taskName = "CA-Config"
$outLog   = "C:\Windows\Temp\ca-task.out"
$errLog   = "C:\Windows\Temp\ca-task.err"

Write-Host "==> Creating scheduled task $taskName as $ru (schtasks.exe)"

# schtasks needs a start time even if we run immediately
$st = (Get-Date).AddMinutes(2).ToString("HH:mm")

# Build the command line that the task will run (logs stdout/stderr)
$tr = "cmd.exe /c powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`" 1>>`"$outLog`" 2>>`"$errLog`""

# Create the task (DON'T echo the command because it contains the password)
Write-Host "==> schtasks /Create ... (password redacted)"
cmd /c "schtasks /Create /TN `"$taskName`" /SC ONCE /ST $st /RL HIGHEST /RU `"$ru`" /RP `"$DomainPassword`" /TR `"$tr`" /F" | Out-Null

# Run it immediately
Write-Host "==> Starting task"
cmd /c "schtasks /Run /TN `"$taskName`"" | Out-Null

# Poll until task is no longer running
Write-Host "==> Waiting for task completion"
$deadline = (Get-Date).AddMinutes(90)

while ((Get-Date) -lt $deadline) {
  $q = cmd /c "schtasks /Query /TN `"$taskName`" /FO LIST /V" 2>&1

  $statusLine     = ($q | Select-String -Pattern '^Status:\s+').ToString()
  $lastResultLine = ($q | Select-String -Pattern '^Last Result:\s+').ToString()

  if ($statusLine -match 'Status:\s+Running') {
    Start-Sleep 15
    continue
  }

  Write-Host $statusLine
  Write-Host $lastResultLine

  $lr = ($lastResultLine -replace 'Last Result:\s+','').Trim()

  if ($lr -eq '0' -or $lr -eq '0x0') {
    Write-Host "==> Task completed successfully"
    Stop-Transcript
    exit 0
  }

  Write-Host "==> Task failed (Last Result: $lr). Tail logs:"
  if (Test-Path $outLog) { Get-Content $outLog -Tail 200 }
  if (Test-Path $errLog) { Get-Content $errLog -Tail 200 }
  throw "CA scheduled task failed (Last Result: $lr). See $outLog / $errLog and $bootstrapLog"
}

throw "Timed out waiting for CA scheduled task to complete."
