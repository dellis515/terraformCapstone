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

# Build task action (PowerShell) + capture logs
$exe  = "powershell.exe"
$args = "-ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`" 1>>`"$outLog`" 2>>`"$errLog`""
$action  = New-ScheduledTaskAction -Execute $exe -Argument $args
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
$principal = New-ScheduledTaskPrincipal -UserId $ru -LogonType Password -RunLevel Highest

Write-Host "==> Registering scheduled task $taskName as $ru"
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Password $DomainPassword | Out-Null

Write-Host "==> Starting task"
Start-ScheduledTask -TaskName $taskName

Write-Host "==> Waiting for task completion"
$deadline = (Get-Date).AddMinutes(90)
do {
  Start-Sleep 10
  $info = Get-ScheduledTaskInfo -TaskName $taskName
} while ($info.State -eq "Running" -and (Get-Date) -lt $deadline)

if ((Get-Date) -ge $deadline) { throw "Timed out waiting for CA scheduled task to complete." }

$info = Get-ScheduledTaskInfo -TaskName $taskName
Write-Host "Status: $($info.State)  LastTaskResult: $($info.LastTaskResult)"

if ($info.LastTaskResult -ne 0) {
  Write-Host "==> Task failed. Tail logs:"
  if (Test-Path $outLog) { Get-Content $outLog -Tail 200 }
  if (Test-Path $errLog) { Get-Content $errLog -Tail 200 }
  throw "CA scheduled task failed. See $outLog / $errLog and C:\Windows\Temp\ca-bootstrap.log"
}

Write-Host "==> CA scheduled task completed successfully"
Stop-Transcript
exit 0
