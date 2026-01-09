$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message)
  $ts = (Get-Date).ToString("s")
  Write-Host "[$ts] $Message"
}

# ---- Settings (override-friendly) ----
$domain     = $env:LAB_DOMAIN  ; if (-not $domain)     { $domain = "dellis.lab" }
$shareName  = $env:SHARE_NAME  ; if (-not $shareName)  { $shareName = "CorpData$" }
$shareDesc  = $env:SHARE_DESC  ; if (-not $shareDesc)  { $shareDesc = "CorpData share" }

# Use NetBIOS prefix from domain (DELLIS from dellis.lab)
$netbios = ($domain.Split(".")[0]).ToUpper()

$adminGroup = $env:ADMIN_GROUP ; if (-not $adminGroup) { $adminGroup = "$netbios\Domain Admins" }
$rwGroup    = $env:RW_GROUP    ; if (-not $rwGroup)    { $rwGroup    = "$netbios\FS_CorpData_RW" }
$roGroup    = $env:RO_GROUP    ; if (-not $roGroup)    { $roGroup    = "$netbios\FS_CorpData_RO" }

# ---- Ensure File Server role ----
Write-Log "Installing File Server role (FS-FileServer) if missing..."
Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools | Out-Null

# ---- Choose a data volume (prefer D: if a data disk exists) ----
function Ensure-DataDisk {
  # Finds a RAW disk (common for newly attached managed disk), initializes it, creates one partition, formats NTFS, assigns next letter (usually D:)
  $rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.OperationalStatus -eq 'Online' }
  foreach ($disk in $rawDisks) {
    Write-Log "Found RAW disk #$($disk.Number). Initializing and formatting..."
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false | Out-Null
  }
}

Ensure-DataDisk

# Prefer a non-OS volume if available
$osDrive = (Get-CimInstance Win32_OperatingSystem).SystemDrive.TrimEnd('\')
$candidate = Get-Volume | Where-Object {
  $_.DriveLetter -and ($_.DriveLetter + ":") -ne $osDrive -and $_.FileSystem -eq "NTFS"
} | Sort-Object -Property Size -Descending | Select-Object -First 1

if ($candidate) {
  $rootDrive = "$($candidate.DriveLetter):"
  Write-Log "Using data volume $rootDrive for shares."
} else {
  $rootDrive = $osDrive
  Write-Log "No separate data volume detected; using OS volume $rootDrive for shares."
}

# ---- Share paths ----
$defaultSharePath = Join-Path $rootDrive "Shares\CorpData"
$sharePath = $env:SHARE_PATH
if (-not $sharePath) { $sharePath = $defaultSharePath }

Write-Log "Ensuring share path exists: $sharePath"
New-Item -Path $sharePath -ItemType Directory -Force | Out-Null

# ---- NTFS permissions (recommended model) ----
# - Admins: Full
# - RW group: Modify
# - RO group: Read
# Remove inherited perms to make it deterministic.
Write-Log "Setting NTFS permissions on $sharePath"

# Disable inheritance, remove inherited ACLs
icacls $sharePath /inheritance:d | Out-Null

# Clear explicit permissions (optional but makes it clean)
# NOTE: icacls doesn't have a "clear all" single switch; easiest is to reset then remove inheritance then grant.
icacls $sharePath /reset | Out-Null
icacls $sharePath /inheritance:d | Out-Null

# Grant permissions
icacls $sharePath /grant "$adminGroup:(OI)(CI)F" | Out-Null
icacls $sharePath /grant "$rwGroup:(OI)(CI)M" | Out-Null
icacls $sharePath /grant "$roGroup:(OI)(CI)RX" | Out-Null

# Optional: remove "Users" if you want tighter default
# icacls $sharePath /remove "BUILTIN\Users" | Out-Null

# ---- SMB share ----
Write-Log "Creating/updating SMB share $shareName -> $sharePath"

# If share exists, update it; otherwise create.
$existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Log "Share already exists; updating description/path permissions if needed."
  # Share path can’t be modified on an existing share; if you need to change path, remove + recreate.
  # Set-SmbShare -Name $shareName -Description $shareDesc -Force | Out-Null
} else {
  New-SmbShare -Name $shareName -Path $sharePath -Description $shareDesc `
    -FullAccess $adminGroup `
    -ChangeAccess $rwGroup `
    -ReadAccess $roGroup | Out-Null
}

# ---- SMB hardening (reasonable defaults for a lab) ----
Write-Log "Applying SMB settings (disable SMB1, enable SMB2/3)..."
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force | Out-Null
Set-SmbServerConfiguration -EnableSMB2Protocol $true  -Force | Out-Null

# ---- Firewall (SMB) ----
Write-Log "Ensuring SMB firewall rules are enabled..."
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing" | Out-Null

# ---- Quick validation ----
Write-Log "Validation:"
Write-Log "  Domain: $domain"
Write-Log "  Share:  \\$env:COMPUTERNAME\$shareName"
Write-Log "  Path:   $sharePath"
Write-Log "Done."
