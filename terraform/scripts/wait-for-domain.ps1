$Domain = "dellis.lab"
$DC     = "10.0.0.4"   # or use the DC private IP / hostname
$TimeoutMinutes = 30
$SleepSeconds   = 15

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

Write-Host "Waiting for domain '$Domain' / DC '$DC' to be ready..."

while ((Get-Date) -lt $deadline) {
  try {
    # 1) DNS
    Resolve-DnsName $Domain -ErrorAction Stop | Out-Null

    # 2) LDAP (389)
    $ldap = Test-NetConnection -ComputerName $DC -Port 389 -WarningAction SilentlyContinue
    if (-not $ldap.TcpTestSucceeded) { throw "LDAP not reachable yet" }

    # 3) SYSVOL (optional but nice)
    if (Test-Path "\\$DC\SYSVOL") {
      Write-Host "Domain looks ready."
      exit 0
    }

    Write-Host "DNS+LDAP ok, waiting for SYSVOL..."
  }
  catch {
    Write-Host "Not ready yet: $($_.Exception.Message)"
  }

  Start-Sleep -Seconds $SleepSeconds
}

Write-Error "Timed out waiting for domain readiness after $TimeoutMinutes minutes."
exit 1
