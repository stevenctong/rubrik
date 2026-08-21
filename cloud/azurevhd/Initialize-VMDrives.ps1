<#
.SYNOPSIS
Initializes, formats, and assigns drive letters to raw disks on a target VM
using drive configuration captured from the source VM.

.DESCRIPTION
After VM conversion to Azure, data disks marked CreateOnly are attached as raw,
uninitialized managed disks. This script reads a drive info CSV (produced by
Get-DriveInfo.ps1 on the source VM), matches raw disks to CSV rows by size,
and initializes each disk with the correct partition style, file system,
allocation unit size, volume label, and drive letter.

Drives that already exist on the system are automatically skipped, making the
script safe to re-run.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/21/26
Updated: 8/21/26

.PARAMETER CsvFile
Path to the drive info CSV file (produced by Get-DriveInfo.ps1).

.PARAMETER ServerName
Filter the CSV to rows matching this server name. If omitted and the CSV
contains multiple servers, the script will error.

.PARAMETER LogFile
Path for the log file. Defaults to ./Initialize-VMDrives.log.

.PARAMETER WhatIf
Preview mode. Shows the match plan without making any changes.

.PARAMETER SkipConfirmation
Skip the confirmation prompt before formatting disks.

.EXAMPLE
./Initialize-VMDrives.ps1 -CsvFile '.\drive_info-SQLSERVER01.csv'
Reads the CSV, matches raw disks, prompts for confirmation, then initializes.

.EXAMPLE
./Initialize-VMDrives.ps1 -CsvFile '.\drive_info.csv' -ServerName 'SQLSERVER01' -WhatIf
Shows what would happen without making changes (filtered to one server).

.EXAMPLE
./Initialize-VMDrives.ps1 -CsvFile '.\drive_info.csv' -SkipConfirmation
Runs without the confirmation prompt.

#>

param (
  [CmdletBinding()]
  [Parameter(Mandatory=$false)]
  [string]$CsvFile = '',
  [Parameter(Mandatory=$false)]
  [string]$ServerName = '',
  [Parameter(Mandatory=$false)]
  [string]$LogFile = './Initialize-VMDrives.log',
  [switch]$WhatIf,
  [switch]$SkipConfirmation
)

if ([string]::IsNullOrEmpty($CsvFile)) {
  Write-Host ""
  Write-Host "Usage: ./Initialize-VMDrives.ps1" -ForegroundColor Cyan
  Write-Host "  -CsvFile <path to drive info CSV from Get-DriveInfo.ps1>"
  Write-Host "  [-ServerName <filter to this server>]"
  Write-Host "  [-LogFile <log file path>] (default: ./Initialize-VMDrives.log)"
  Write-Host "  [-WhatIf] (preview mode, no changes)"
  Write-Host "  [-SkipConfirmation] (skip confirmation prompt)"
  Write-Host ""
  exit
}

# ============================================================================
# Write-Log helper
# ============================================================================

$script:logPath = $LogFile

function Write-Log {
  param (
    [string]$Message,
    [string]$Color = 'White',
    [switch]$NoConsole
  )
  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $logLine = "[$timestamp] $Message"
  Add-Content -Path $script:logPath -Value $logLine -ErrorAction SilentlyContinue
  if (-not $NoConsole) {
    Write-Host $Message -ForegroundColor $Color
  }
}

# ============================================================================
# Read and validate CSV
# ============================================================================

Write-Log "Initialize-VMDrives started" -Color Cyan
Write-Log "CSV file: $CsvFile"

if (-not (Test-Path $CsvFile)) {
  Write-Log "ERROR: CSV file not found: $CsvFile" -Color Red
  exit 1
}

$csvData = Import-Csv -Path $CsvFile

$requiredColumns = @('Drive', 'TotalCapacityMB', 'DriveType')
foreach ($col in $requiredColumns) {
  if ($col -notin $csvData[0].PSObject.Properties.Name) {
    Write-Log "ERROR: CSV is missing required column: $col" -Color Red
    exit 1
  }
}

# Filter by ServerName if specified
$serverNames = @($csvData | ForEach-Object { $_.ServerName } | Sort-Object -Unique)
if (-not [string]::IsNullOrEmpty($ServerName)) {
  $csvData = @($csvData | Where-Object { $_.ServerName -eq $ServerName })
  if ($csvData.Count -eq 0) {
    Write-Log "ERROR: No rows found for server '$ServerName'. Available: $($serverNames -join ', ')" -Color Red
    exit 1
  }
  Write-Log "Filtered to server: $ServerName ($($csvData.Count) rows)"
} elseif ($serverNames.Count -gt 1) {
  Write-Log "ERROR: CSV contains multiple servers ($($serverNames -join ', ')). Use -ServerName to filter." -Color Red
  exit 1
} else {
  Write-Log "Server: $($serverNames[0]) ($($csvData.Count) rows)"
}

# ============================================================================
# Identify drives to skip (already exist on the system)
# ============================================================================

$existingVolumes = @{}
Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
  $existingVolumes[$_.DriveLetter] = $_
}

$drivesToProcess = @()
$drivesSkipped = @()

foreach ($row in $csvData) {
  $letter = $row.Drive
  if ([string]::IsNullOrEmpty($letter)) { continue }
  $letterChar = [char]$letter[0]

  if ($existingVolumes.ContainsKey($letterChar)) {
    $drivesSkipped += $row
    Write-Log "  Skip drive ${letter}: already exists ($(
      $existingVolumes[$letterChar].FileSystemLabel
    ), $([math]::Round($existingVolumes[$letterChar].Size / 1MB)) MB)" -Color DarkGray
  } else {
    $drivesToProcess += $row
  }
}

Write-Log ""
Write-Log "$($drivesSkipped.Count) drive(s) skipped (already exist), $($drivesToProcess.Count) drive(s) to process"

if ($drivesToProcess.Count -eq 0) {
  Write-Log "No drives to initialize. All drives from the CSV already exist." -Color Green
  exit 0
}

# ============================================================================
# Get raw (uninitialized) disks
# ============================================================================

$rawDisks = @(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Size -Descending)
Write-Log "$($rawDisks.Count) raw (uninitialized) disk(s) found on system"

if ($rawDisks.Count -eq 0) {
  Write-Log "ERROR: No raw disks found but $($drivesToProcess.Count) drive(s) need initialization." -Color Red
  Write-Log "Ensure the disks are attached and not already initialized." -Color Yellow
  exit 1
}

if ($rawDisks.Count -lt $drivesToProcess.Count) {
  Write-Log "WARNING: Only $($rawDisks.Count) raw disk(s) available for $($drivesToProcess.Count) drive(s) to process." -Color Yellow
  Write-Log "Some drives will not be matched." -Color Yellow
}

# ============================================================================
# Match raw disks to CSV rows by size
# ============================================================================

$sortedCsvRows = @($drivesToProcess | Sort-Object { [double]$_.TotalCapacityMB } -Descending)
$availableDisks = [System.Collections.ArrayList]@($rawDisks)

$matchPlan = @()
$unmatchedRows = @()

foreach ($row in $sortedCsvRows) {
  $csvSizeMB = [double]$row.TotalCapacityMB
  $bestMatch = $null
  $bestDiff = [double]::MaxValue

  foreach ($disk in $availableDisks) {
    $diskSizeMB = [math]::Round($disk.Size / 1MB)
    $diff = [math]::Abs($diskSizeMB - $csvSizeMB)
    $pctDiff = if ($csvSizeMB -gt 0) { $diff / $csvSizeMB } else { 1 }

    if ($pctDiff -le 0.10 -and $diff -lt $bestDiff) {
      $bestMatch = $disk
      $bestDiff = $diff
    }
  }

  if ($null -ne $bestMatch) {
    $matchPlan += [PSCustomObject]@{
      Drive            = $row.Drive
      DriveType        = $row.DriveType
      CsvSizeMB        = $csvSizeMB
      DiskNumber       = $bestMatch.Number
      DiskSizeMB       = [math]::Round($bestMatch.Size / 1MB)
      FileSystem       = if ($row.PSObject.Properties.Name -contains 'FileSystem' -and
                             -not [string]::IsNullOrEmpty($row.FileSystem)) {
                           $row.FileSystem
                         } else { 'NTFS' }
      AllocUnitBytes   = if ($row.PSObject.Properties.Name -contains 'AllocationUnitSizeKB' -and
                             -not [string]::IsNullOrEmpty($row.AllocationUnitSizeKB)) {
                           [int]$row.AllocationUnitSizeKB * 1024
                         } else { 4096 }
      AllocUnitDisplay = if ($row.PSObject.Properties.Name -contains 'AllocationUnitSizeKB' -and
                             -not [string]::IsNullOrEmpty($row.AllocationUnitSizeKB)) {
                           "$($row.AllocationUnitSizeKB) KB"
                         } else { '4 KB (default)' }
      PartitionStyle   = if ($row.PSObject.Properties.Name -contains 'PartitionStyle' -and
                             -not [string]::IsNullOrEmpty($row.PartitionStyle)) {
                           $row.PartitionStyle
                         } else { 'GPT' }
      VolumeLabel      = $row.DriveType
      DiskObject       = $bestMatch
    }
    $availableDisks.Remove($bestMatch) | Out-Null
  } else {
    $unmatchedRows += $row
  }
}

# Check for ambiguous matches (multiple CSV rows matched to same-size disks)
$diskSizeCounts = @{}
foreach ($m in $matchPlan) {
  $sizeKey = $m.DiskSizeMB
  if (-not $diskSizeCounts.ContainsKey($sizeKey)) {
    $diskSizeCounts[$sizeKey] = 0
  }
  $diskSizeCounts[$sizeKey]++
}
$ambiguousSizes = @($diskSizeCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 })
if ($ambiguousSizes.Count -gt 0) {
  Write-Log ""
  Write-Log "WARNING: Multiple disks of the same size detected. Drive letter assignment" -Color Yellow
  Write-Log "  for same-size disks is based on CSV order and may be interchangeable." -Color Yellow
  foreach ($a in $ambiguousSizes) {
    $letters = ($matchPlan | Where-Object { $_.DiskSizeMB -eq $a.Key } |
      ForEach-Object { $_.Drive }) -join ', '
    Write-Log "  $($a.Key) MB: drives $letters" -Color Yellow
  }
}

# ============================================================================
# Display match plan
# ============================================================================

Write-Log ""
Write-Log "=== Drive Initialization Plan ===" -Color Cyan
Write-Log ""

$matchPlan | Format-Table @(
  @{ Label = 'Drive'; Expression = { "$($_.Drive):" } }
  @{ Label = 'Label'; Expression = { $_.VolumeLabel } }
  @{ Label = 'CSV Size'; Expression = { "$($_.CsvSizeMB) MB" }; Align = 'Right' }
  @{ Label = 'Disk #'; Expression = { $_.DiskNumber }; Align = 'Right' }
  @{ Label = 'Disk Size'; Expression = { "$($_.DiskSizeMB) MB" }; Align = 'Right' }
  @{ Label = 'FS'; Expression = { $_.FileSystem } }
  @{ Label = 'Alloc Unit'; Expression = { $_.AllocUnitDisplay } }
  @{ Label = 'Partition'; Expression = { $_.PartitionStyle } }
) -AutoSize | Out-String | ForEach-Object { $_.Trim() } | ForEach-Object {
  Write-Log $_ -NoConsole
  Write-Host $_
}

if ($unmatchedRows.Count -gt 0) {
  Write-Log ""
  Write-Log "WARNING: $($unmatchedRows.Count) drive(s) could not be matched to a raw disk:" -Color Yellow
  foreach ($u in $unmatchedRows) {
    Write-Log "  Drive $($u.Drive): $($u.TotalCapacityMB) MB ($($u.DriveType)) -- no raw disk of similar size" -Color Yellow
  }
}

Write-Log ""

# WhatIf exits here
if ($WhatIf) {
  Write-Log "WhatIf mode -- no changes made." -Color Cyan
  Write-Log "Log file: $LogFile"
  exit 0
}

# Confirmation prompt
if (-not $SkipConfirmation) {
  Write-Host ""
  Write-Host "This will initialize and format $($matchPlan.Count) disk(s). This cannot be undone." -ForegroundColor Yellow
  Write-Host "Use -SkipConfirmation to skip this prompt in the future." -ForegroundColor DarkGray
  $confirm = Read-Host "Continue? (Y/N)"
  if ($confirm -notmatch '^[yY]') {
    Write-Log "User cancelled."
    exit 0
  }
  Write-Log "User confirmed. Proceeding..." -NoConsole
}

# ============================================================================
# Initialize, partition, format, and assign drive letters
# ============================================================================

$successCount = 0
$failCount = 0

foreach ($match in $matchPlan) {
  $diskNum = $match.DiskNumber
  $letter = $match.Drive
  $label = $match.VolumeLabel
  $fs = $match.FileSystem
  $allocUnit = $match.AllocUnitBytes
  $partStyle = $match.PartitionStyle
  Write-Log ""
  Write-Log "--- Processing drive ${letter}: (Disk $diskNum, $($match.DiskSizeMB) MB) ---" -Color Cyan

  try {
    # Step 1: Initialize
    Write-Log "  Initializing disk $diskNum as $partStyle..."
    Initialize-Disk -Number $diskNum -PartitionStyle $partStyle -ErrorAction Stop
    Write-Log "  Disk $diskNum initialized." -Color Green

    # Step 2: Create partition with drive letter
    Write-Log "  Creating partition with drive letter ${letter}:..."
    $newPartition = New-Partition -DiskNumber $diskNum -UseMaximumSize `
      -DriveLetter $letter -ErrorAction Stop
    Write-Log "  Partition created: drive ${letter}:" -Color Green

    # Step 3: Format volume
    $allocDisplay = if ($allocUnit -ge 1024) { "$($allocUnit / 1024) KB" } else { "$allocUnit B" }
    Write-Log "  Formatting ${letter}: as $fs (allocation unit: $allocDisplay, label: $label)..."
    Format-Volume -DriveLetter $letter -FileSystem $fs `
      -AllocationUnitSize $allocUnit -NewFileSystemLabel $label `
      -Confirm:$false -ErrorAction Stop | Out-Null
    Write-Log "  Volume ${letter}: formatted successfully." -Color Green

    $successCount++
  } catch {
    Write-Log "  ERROR on drive ${letter}: $($_.Exception.Message)" -Color Red
    $failCount++
  }
}

# ============================================================================
# Summary
# ============================================================================

Write-Log ""
Write-Log "=== Summary ===" -Color Cyan
Write-Log "  Drives processed:  $($matchPlan.Count)"
Write-Log "  Successful:        $successCount" -Color Green
if ($failCount -gt 0) {
  Write-Log "  Failed:            $failCount" -Color Red
}
if ($drivesSkipped.Count -gt 0) {
  Write-Log "  Skipped (existed): $($drivesSkipped.Count)" -Color DarkGray
}
if ($unmatchedRows.Count -gt 0) {
  Write-Log "  Unmatched:         $($unmatchedRows.Count)" -Color Yellow
}
Write-Log ""
Write-Log "Log file: $LogFile" -Color Cyan
