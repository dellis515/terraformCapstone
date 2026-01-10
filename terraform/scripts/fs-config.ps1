$ErrorActionPreference = "Stop"


$sharePath = "C:\Shares\CorpData"
$shareName = "CorpData"
$adminGroup = "DELLIS\Domain Admins"

Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools | Out-Null

New-Item -Path $sharePath -ItemType Directory -Force | Out-Null

# Reset ACLs to defaults, then disable inheritance, then grant Domain Admins Full
icacls $sharePath /grant "DELLIS\Domain Admins:(OI)(CI)F" | Out-Null

$existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if (-not $existing) {
  New-SmbShare -Name $shareName -Path $sharePath -FullAccess $adminGroup | Out-Null
} else {
  Write-Log "Share already exists; leaving as-is."
}