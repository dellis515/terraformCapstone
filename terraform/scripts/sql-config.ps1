# sql-config.ps1
$ErrorActionPreference = "Stop"

$domain = $env:LAB_DOMAIN
if (-not $domain) { $domain = "dellis.lab" }
$netbios = ($domain.Split(".")[0]).ToUpper()
$sqlAdmins = "$netbios\Domain Admins"

$workDir   = "C:\SQLInstall"
$mediaDir  = Join-Path $workDir "Media"
$isoPath   = Join-Path $mediaDir "SQLServer.iso"

New-Item -Path $workDir  -ItemType Directory -Force | Out-Null
New-Item -Path $mediaDir -ItemType Directory -Force | Out-Null

# 1) Download the Developer bootstrapper (downloads ISO for you)
$bootstrap = Join-Path $workDir "SQL2022-SSEI-Dev.exe"
$bootstrapUrl = "https://download.microsoft.com/download/1/2/c/12cdb65d-1bb6-4c78-a922-0d00cc430d0c/SQL2022-SSEI-Dev.exe"

Write-Host "Downloading SQL bootstrapper..."
Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrap -UseBasicParsing

# 2) Download ISO media locally
Write-Host "Downloading SQL ISO media to $mediaDir ..."
# /ACTION=Download + /MEDIATYPE=ISO makes the exe fetch an ISO file
& $bootstrap /ACTION=Download /MEDIATYPE=ISO /MEDIAPATH="$mediaDir" /QUIET

# Heuristic: find the newest ISO if the name isn't exactly what we expect
$iso = Get-ChildItem -Path $mediaDir -Filter "*.iso" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $iso) { throw "No ISO found in $mediaDir after download." }
$isoPath = $iso.FullName
Write-Host "ISO ready: $isoPath"

# 3) Mount ISO and run setup silently
Write-Host "Mounting ISO..."
$disk = Mount-DiskImage -ImagePath $isoPath -PassThru
Start-Sleep -Seconds 3
$vol = $disk | Get-Volume
$drive = $vol.DriveLetter + ":"
$setup = Join-Path $drive "setup.exe"
if (-not (Test-Path $setup)) { throw "setup.exe not found at $setup" }

Write-Host "Installing SQL Server Engine..."
# Minimal: default instance, Windows auth, Domain Admins are sysadmins, enable TCP
$args = @(
  "/Q",
  "/ACTION=Install",
  "/FEATURES=SQLENGINE",
  "/INSTANCENAME=MSSQLSERVER",
  "/SQLSYSADMINACCOUNTS=`"$sqlAdmins`"",
  "/TCPENABLED=1",
  "/IACCEPTSQLSERVERLICENSETERMS"
)

$proc = Start-Process -FilePath $setup -ArgumentList $args -Wait -PassThru
if ($proc.ExitCode -ne 0) { throw "SQL setup failed with exit code $($proc.ExitCode)" }

# 4) Open firewall for SQL (lab-internal)
Write-Host "Opening firewall for SQL (TCP 1433)..."
New-NetFirewallRule -DisplayName "SQL Server (TCP 1433)" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null

Write-Host "Dismounting ISO..."
Dismount-DiskImage -ImagePath $isoPath

Write-Host "SQL install done."
