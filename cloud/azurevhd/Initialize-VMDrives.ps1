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

Handles multi-partition disks (multiple volumes on one physical disk) by
grouping CSV rows by source disk number and creating sized partitions.
Dynamic disks are detected and skipped with a warning.

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

$hasDiskNumber = 'DiskNumber' -in $csvData[0].PSObject.Properties.Name
$hasDiskType = 'DiskType' -in $csvData[0].PSObject.Properties.Name
$hasDiskSizeGB = 'DiskSizeGB' -in $csvData[0].PSObject.Properties.Name
$hasPartitionsOnDisk = 'PartitionsOnDisk' -in $csvData[0].PSObject.Properties.Name

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
# Filter: skip existing drives, dynamic disks
# ============================================================================

$existingVolumes = @{}
Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
  $existingVolumes[$_.DriveLetter] = $_
}

$drivesToProcess = @()
$drivesSkipped = @()
$dynamicSkipped = @()

foreach ($row in $csvData) {
  $letter = $row.Drive
  if ([string]::IsNullOrEmpty($letter)) { continue }
  $letterChar = [char]$letter[0]

  # Skip dynamic disk rows
  if ($hasDiskType -and $row.DiskType -eq 'Dynamic') {
    $dynamicSkipped += $row
    Write-Log "  Skip drive ${letter}: source was a dynamic disk (requires manual setup)" -Color Yellow
    continue
  }

  # Skip drives that already exist
  if ($existingVolumes.ContainsKey($letterChar)) {
    $drivesSkipped += $row
    Write-Log "  Skip drive ${letter}: already exists ($(
      $existingVolumes[$letterChar].FileSystemLabel
    ), $([math]::Round($existingVolumes[$letterChar].Size / 1MB)) MB)" -Color DarkGray
    continue
  }

  $drivesToProcess += $row
}

Write-Log ""
Write-Log "$($drivesSkipped.Count) drive(s) skipped (already exist), $($dynamicSkipped.Count) skipped (dynamic), $($drivesToProcess.Count) to process"

if ($dynamicSkipped.Count -gt 0) {
  Write-Log ""
  Write-Log "Dynamic disk drives skipped (manual setup required):" -Color Yellow
  foreach ($d in $dynamicSkipped) {
    Write-Log "  Drive $($d.Drive): $($d.TotalCapacityMB) MB ($($d.DriveType)) on disk $($d.DiskNumber)" -Color Yellow
  }
}

if ($drivesToProcess.Count -eq 0) {
  Write-Log "No drives to initialize." -Color Green
  exit 0
}

# ============================================================================
# Group drives by source disk number (multi-partition detection)
# ============================================================================

$diskGroups = @{}

if ($hasDiskNumber) {
  foreach ($row in $drivesToProcess) {
    $dn = $row.DiskNumber
    if ([string]::IsNullOrEmpty($dn)) { $dn = "unknown_$($row.Drive)" }
    if (-not $diskGroups.ContainsKey($dn)) {
      $diskGroups[$dn] = @()
    }
    $diskGroups[$dn] += $row
  }
} else {
  # No DiskNumber column -- treat each row as its own disk
  foreach ($row in $drivesToProcess) {
    $key = "row_$($row.Drive)"
    $diskGroups[$key] = @($row)
  }
}

$singlePartGroups = @()
$multiPartGroups = @()
foreach ($key in $diskGroups.Keys) {
  if ($diskGroups[$key].Count -eq 1) {
    $singlePartGroups += @{ Key = $key; Rows = $diskGroups[$key] }
  } else {
    $multiPartGroups += @{ Key = $key; Rows = $diskGroups[$key] }
  }
}

if ($multiPartGroups.Count -gt 0) {
  Write-Log ""
  Write-Log "Multi-partition disk(s) detected:" -Color Yellow
  foreach ($g in $multiPartGroups) {
    $letters = ($g.Rows | ForEach-Object { $_.Drive }) -join ', '
    $totalMB = ($g.Rows | ForEach-Object { [double]$_.TotalCapacityMB } | Measure-Object -Sum).Sum
    Write-Log "  Source disk $($g.Key): drives $letters (total volume capacity: $totalMB MB)" -Color Yellow
  }
}

# ============================================================================
# Get raw (uninitialized) disks
# ============================================================================

$rawDisks = @(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Size -Descending)
Write-Log ""
Write-Log "$($rawDisks.Count) raw (uninitialized) disk(s) found on system"

$totalDisksNeeded = $singlePartGroups.Count + $multiPartGroups.Count
if ($rawDisks.Count -eq 0) {
  Write-Log "ERROR: No raw disks found but $totalDisksNeeded disk(s) need initialization." -Color Red
  exit 1
}

if ($rawDisks.Count -lt $totalDisksNeeded) {
  Write-Log "WARNING: Only $($rawDisks.Count) raw disk(s) available for $totalDisksNeeded needed." -Color Yellow
}

# ============================================================================
# Match raw disks to CSV rows/groups by size
# ============================================================================

$availableDisks = [System.Collections.ArrayList]@($rawDisks)
$matchPlan = @()
$unmatchedRows = @()

# Helper: find best matching raw disk within tolerance
function Find-BestDisk {
  param ([double]$TargetMB, [System.Collections.ArrayList]$Pool)
  $bestMatch = $null
  $bestDiff = [double]::MaxValue
  foreach ($disk in $Pool) {
    $diskMB = [math]::Round($disk.Size / 1MB)
    $diff = [math]::Abs($diskMB - $TargetMB)
    $pctDiff = if ($TargetMB -gt 0) { $diff / $TargetMB } else { 1 }
    if ($pctDiff -le 0.10 -and $diff -lt $bestDiff) {
      $bestMatch = $disk
      $bestDiff = $diff
    }
  }
  return $bestMatch
}

# Helper: get formatting properties from a CSV row
function Get-FormatProps {
  param ($Row)
  $props = @{
    FileSystem = 'NTFS'
    AllocUnitBytes = 4096
    AllocUnitDisplay = '4 KB (default)'
    PartitionStyle = 'GPT'
  }
  if ($Row.PSObject.Properties.Name -contains 'FileSystem' -and
      -not [string]::IsNullOrEmpty($Row.FileSystem)) {
    $props.FileSystem = $Row.FileSystem
  }
  if ($Row.PSObject.Properties.Name -contains 'AllocationUnitSizeKB' -and
      -not [string]::IsNullOrEmpty($Row.AllocationUnitSizeKB)) {
    $props.AllocUnitBytes = [int]$Row.AllocationUnitSizeKB * 1024
    $props.AllocUnitDisplay = "$($Row.AllocationUnitSizeKB) KB"
  }
  if ($Row.PSObject.Properties.Name -contains 'PartitionStyle' -and
      -not [string]::IsNullOrEmpty($Row.PartitionStyle)) {
    $props.PartitionStyle = $Row.PartitionStyle
  }
  return $props
}

# Match multi-partition groups first (use total disk size)
foreach ($g in ($multiPartGroups | Sort-Object { ($_.Rows | ForEach-Object { [double]$_.TotalCapacityMB } | Measure-Object -Sum).Sum } -Descending)) {
  $rows = $g.Rows
  # Use DiskSizeGB from CSV if available, otherwise sum volume capacities + 10% overhead
  $matchSizeMB = 0
  if ($hasDiskSizeGB -and -not [string]::IsNullOrEmpty($rows[0].DiskSizeGB)) {
    $matchSizeMB = [double]$rows[0].DiskSizeGB * 1024
  } else {
    $totalVolMB = ($rows | ForEach-Object { [double]$_.TotalCapacityMB } | Measure-Object -Sum).Sum
    $matchSizeMB = $totalVolMB * 1.05
  }

  $bestDisk = Find-BestDisk -TargetMB $matchSizeMB -Pool $availableDisks
  if ($null -ne $bestDisk) {
    $firstRow = $rows[0]
    $fp = Get-FormatProps -Row $firstRow
    foreach ($row in ($rows | Sort-Object { [double]$_.TotalCapacityMB } -Descending)) {
      $rowFp = Get-FormatProps -Row $row
      $matchPlan += [PSCustomObject]@{
        Drive            = $row.Drive
        DriveType        = $row.DriveType
        CsvSizeMB        = [double]$row.TotalCapacityMB
        DiskNumber       = $bestDisk.Number
        DiskSizeMB       = [math]::Round($bestDisk.Size / 1MB)
        FileSystem       = $rowFp.FileSystem
        AllocUnitBytes   = $rowFp.AllocUnitBytes
        AllocUnitDisplay = $rowFp.AllocUnitDisplay
        PartitionStyle   = $fp.PartitionStyle
        VolumeLabel      = $row.DriveType
        MultiPartition   = $true
        IsLastPartition  = $false
        DiskObject       = $bestDisk
      }
    }
    # Mark last partition (gets UseMaximumSize)
    $groupMatches = @($matchPlan | Where-Object { $_.DiskNumber -eq $bestDisk.Number })
    $groupMatches[-1].IsLastPartition = $true
    $availableDisks.Remove($bestDisk) | Out-Null
  } else {
    foreach ($row in $rows) { $unmatchedRows += $row }
  }
}

# Match single-partition groups (use volume capacity)
foreach ($g in ($singlePartGroups | Sort-Object { [double]$_.Rows[0].TotalCapacityMB } -Descending)) {
  $row = $g.Rows[0]
  $csvSizeMB = [double]$row.TotalCapacityMB
  $bestDisk = Find-BestDisk -TargetMB $csvSizeMB -Pool $availableDisks

  if ($null -ne $bestDisk) {
    $fp = Get-FormatProps -Row $row
    $matchPlan += [PSCustomObject]@{
      Drive            = $row.Drive
      DriveType        = $row.DriveType
      CsvSizeMB        = $csvSizeMB
      DiskNumber       = $bestDisk.Number
      DiskSizeMB       = [math]::Round($bestDisk.Size / 1MB)
      FileSystem       = $fp.FileSystem
      AllocUnitBytes   = $fp.AllocUnitBytes
      AllocUnitDisplay = $fp.AllocUnitDisplay
      PartitionStyle   = $fp.PartitionStyle
      VolumeLabel      = $row.DriveType
      MultiPartition   = $false
      IsLastPartition  = $true
      DiskObject       = $bestDisk
    }
    $availableDisks.Remove($bestDisk) | Out-Null
  } else {
    $unmatchedRows += $row
  }
}

# Check for ambiguous matches (same-size disks)
$diskSizeCounts = @{}
$uniqueDisks = @($matchPlan | ForEach-Object { $_.DiskNumber } | Sort-Object -Unique)
foreach ($dn in $uniqueDisks) {
  $sizeMB = ($matchPlan | Where-Object { $_.DiskNumber -eq $dn } | Select-Object -First 1).DiskSizeMB
  if (-not $diskSizeCounts.ContainsKey($sizeMB)) { $diskSizeCounts[$sizeMB] = @() }
  $diskSizeCounts[$sizeMB] += $dn
}
$ambiguousSizes = @($diskSizeCounts.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
if ($ambiguousSizes.Count -gt 0) {
  Write-Log ""
  Write-Log "WARNING: Multiple raw disks of the same size. Drive letter assignment" -Color Yellow
  Write-Log "  for same-size disks is based on CSV order and may be interchangeable." -Color Yellow
  foreach ($a in $ambiguousSizes) {
    $diskNums = $a.Value -join ', '
    Write-Log "  $($a.Key) MB: disks $diskNums" -Color Yellow
  }
}

# ============================================================================
# Display match plan
# ============================================================================

Write-Log ""
Write-Log "=== Drive Initialization Plan ===" -Color Cyan
Write-Log ""

$matchPlan | Sort-Object Drive | Format-Table @(
  @{ Label = 'Drive'; Expression = { "$($_.Drive):" } }
  @{ Label = 'Label'; Expression = { $_.VolumeLabel } }
  @{ Label = 'Vol Size'; Expression = { "$($_.CsvSizeMB) MB" }; Align = 'Right' }
  @{ Label = 'Disk #'; Expression = { $_.DiskNumber }; Align = 'Right' }
  @{ Label = 'Disk Size'; Expression = { "$($_.DiskSizeMB) MB" }; Align = 'Right' }
  @{ Label = 'FS'; Expression = { $_.FileSystem } }
  @{ Label = 'Alloc Unit'; Expression = { $_.AllocUnitDisplay } }
  @{ Label = 'Partition'; Expression = { $_.PartitionStyle } }
  @{ Label = 'Multi'; Expression = { if ($_.MultiPartition) { 'Y' } else { '' } } }
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
  Write-Host "This will initialize and format $($matchPlan.Count) volume(s) on $($uniqueDisks.Count) disk(s). This cannot be undone." -ForegroundColor Yellow
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
$initializedDisks = @{}

# Sort by disk number so we process all partitions on the same disk together
$sortedPlan = @($matchPlan | Sort-Object DiskNumber, { [double]$_.CsvSizeMB } -Descending)

foreach ($match in $sortedPlan) {
  $diskNum = $match.DiskNumber
  $letter = $match.Drive
  $label = $match.VolumeLabel
  $fs = $match.FileSystem
  $allocUnit = $match.AllocUnitBytes
  $partStyle = $match.PartitionStyle
  $isMulti = $match.MultiPartition
  $isLast = $match.IsLastPartition

  Write-Log ""
  Write-Log "--- Processing drive ${letter}: (Disk $diskNum, volume $($match.CsvSizeMB) MB) ---" -Color Cyan

  try {
    # Step 1: Initialize disk (only once per disk)
    if (-not $initializedDisks.ContainsKey($diskNum)) {
      Write-Log "  Initializing disk $diskNum as $partStyle..."
      Initialize-Disk -Number $diskNum -PartitionStyle $partStyle -ErrorAction Stop
      Write-Log "  Disk $diskNum initialized." -Color Green
      $initializedDisks[$diskNum] = $true
    }

    # Step 2: Create partition
    if ($isMulti -and -not $isLast) {
      $partSizeBytes = [int64]([double]$match.CsvSizeMB * 1MB)
      Write-Log "  Creating partition ($($match.CsvSizeMB) MB) with drive letter ${letter}:..."
      $newPartition = New-Partition -DiskNumber $diskNum -Size $partSizeBytes `
        -DriveLetter $letter -ErrorAction Stop
    } else {
      Write-Log "  Creating partition (max size) with drive letter ${letter}:..."
      $newPartition = New-Partition -DiskNumber $diskNum -UseMaximumSize `
        -DriveLetter $letter -ErrorAction Stop
    }
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
Write-Log "  Volumes processed: $($matchPlan.Count)"
Write-Log "  Successful:        $successCount" -Color Green
if ($failCount -gt 0) {
  Write-Log "  Failed:            $failCount" -Color Red
}
if ($drivesSkipped.Count -gt 0) {
  Write-Log "  Skipped (existed): $($drivesSkipped.Count)" -Color DarkGray
}
if ($dynamicSkipped.Count -gt 0) {
  Write-Log "  Skipped (dynamic): $($dynamicSkipped.Count)" -Color Yellow
}
if ($unmatchedRows.Count -gt 0) {
  Write-Log "  Unmatched:         $($unmatchedRows.Count)" -Color Yellow
}
Write-Log ""
Write-Log "Log file: $LogFile" -Color Cyan
