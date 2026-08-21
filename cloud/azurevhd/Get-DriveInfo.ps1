<#
.SYNOPSIS
Captures drive configuration from a Windows VM to a CSV file.

.DESCRIPTION
Enumerates all volumes with drive letters on the local machine and captures
disk, partition, and volume details to a CSV. The output CSV is consumed by
Initialize-VMDrives.ps1 on the target VM after migration to recreate drive
letters, formatting, and volume labels.

Also detects and warns about dynamic disks, multi-partition disks, and
mount point volumes that require manual intervention after migration.

Run this script on the source VM before migration.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/21/26
Updated: 8/21/26

.PARAMETER OutputPath
Path for the output CSV file. Defaults to ./drive_info-{COMPUTERNAME}.csv.

.EXAMPLE
./Get-DriveInfo.ps1
Captures drive info to ./drive_info-SERVERNAME.csv

.EXAMPLE
./Get-DriveInfo.ps1 -OutputPath 'C:\temp\drives.csv'
Captures drive info to the specified path

#>

param (
  [CmdletBinding()]
  [Parameter(Mandatory=$false)]
  [string]$OutputPath = "./drive_info-$($env:COMPUTERNAME).csv"
)

# Build Win32_Volume lookup for allocation unit size
$volLookup = @{}
Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
  $volLookup[$_.DriveLetter[0]] = $_
}

$systemDriveLetter = $env:SystemDrive[0]

# Pre-scan: build per-disk volume count and dynamic disk detection
$diskInfo = @{}
$volumes = Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter

foreach ($vol in $volumes) {
  try {
    $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop
    $dn = $part.DiskNumber
    if (-not $diskInfo.ContainsKey($dn)) {
      $disk = Get-Disk -Number $dn -ErrorAction Stop

      $isDynamic = $false
      $wmiParts = Get-CimInstance Win32_DiskPartition -Filter "DiskIndex=$dn" -ErrorAction SilentlyContinue
      if ($wmiParts | Where-Object { $_.Type -match 'Logical Disk Manager' }) {
        $isDynamic = $true
      }

      $diskInfo[$dn] = @{
        Disk = $disk
        IsDynamic = $isDynamic
        VolumeCount = 0
      }
    }
    $diskInfo[$dn].VolumeCount++
  } catch {}
}

# Build drive output
$driveOutput = @()

foreach ($vol in $volumes) {
  $letter = $vol.DriveLetter
  $partition = $null
  $disk = $null
  $allocUnitKB = ''
  $diskNumber = ''
  $busType = ''
  $scsiTarget = ''
  $diskSizeGB = ''
  $partStyle = ''
  $isSystem = ''
  $diskType = ''
  $partitionsOnDisk = ''

  try {
    $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $diskNumber = $disk.Number
    $busType = $disk.BusType
    $partStyle = $disk.PartitionStyle
    $diskSizeGB = [math]::Round($disk.Size / 1GB, 1)
    if ($disk.Location -match 'Target Id (\d+)') {
      $scsiTarget = $Matches[1]
    } elseif ($disk.Location -match 'LUN (\d+)') {
      $scsiTarget = $Matches[1]
    }
    $isSystem = if ($partition.IsSystem -or $partition.IsBoot) { 'Y' } else { '' }

    if ($diskInfo.ContainsKey($disk.Number)) {
      $diskType = if ($diskInfo[$disk.Number].IsDynamic) { 'Dynamic' } else { 'Basic' }
      $partitionsOnDisk = $diskInfo[$disk.Number].VolumeCount
    }
  } catch {
    Write-Warning "Could not get partition/disk info for drive ${letter}: $($_.Exception.Message)"
  }

  if ($volLookup.ContainsKey($letter)) {
    $w32 = $volLookup[$letter]
    if ($w32.BlockSize -gt 0) {
      $allocUnitKB = [math]::Round($w32.BlockSize / 1024)
    }
  }

  $isBoot = if ($letter -eq $systemDriveLetter) { 'Y' } else { '' }

  $driveOutput += [PSCustomObject]@{
    ServerName           = $env:COMPUTERNAME
    Drive                = $letter
    DriveType            = $vol.FileSystemLabel
    TotalCapacityMB      = [math]::Round($vol.Size / 1MB)
    UsedSpaceMB          = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1MB)
    TotalCapacityBytes   = $vol.Size
    FileSystem           = $vol.FileSystemType
    AllocationUnitSizeKB = $allocUnitKB
    PartitionStyle       = $partStyle
    DiskNumber           = $diskNumber
    DiskType             = $diskType
    PartitionsOnDisk     = $partitionsOnDisk
    BusType              = $busType
    ScsiTarget           = $scsiTarget
    DiskSizeGB           = $diskSizeGB
    IsSystem             = $isSystem
    IsBoot               = $isBoot
  }
}

# Detect mount point volumes (no drive letter, but have a folder access path)
$mountPoints = @()
$allPartitions = Get-Partition -ErrorAction SilentlyContinue |
  Where-Object { -not $_.DriveLetter -and $_.AccessPaths }
foreach ($mp in $allPartitions) {
  $folderPaths = @($mp.AccessPaths | Where-Object { $_ -match '^[A-Z]:\\' -and $_ -notmatch '^\\\\\?\\' })
  if ($folderPaths.Count -gt 0) {
    $mountPoints += [PSCustomObject]@{
      DiskNumber = $mp.DiskNumber
      MountPath  = $folderPaths[0]
      SizeMB     = [math]::Round($mp.Size / 1MB)
    }
  }
}

# Export CSV
$driveOutput | Export-Csv -Path $OutputPath -NoTypeInformation

# Display results
Write-Host ""
Write-Host "Drive info for $($env:COMPUTERNAME) ($($driveOutput.Count) volumes):" -ForegroundColor Green
$driveOutput | Format-Table Drive, DriveType, TotalCapacityMB, FileSystem,
  AllocationUnitSizeKB, PartitionStyle, DiskType, PartitionsOnDisk, DiskNumber, IsBoot -AutoSize

# Warnings
$dynamicDrives = @($driveOutput | Where-Object { $_.DiskType -eq 'Dynamic' })
if ($dynamicDrives.Count -gt 0) {
  Write-Host "WARNING: Dynamic disk(s) detected. These require manual configuration after migration." -ForegroundColor Yellow
  $dynamicDrives | ForEach-Object {
    Write-Host "  Drive $($_.Drive): on disk $($_.DiskNumber) (Dynamic)" -ForegroundColor Yellow
  }
  Write-Host ""
}

$multiPartDisks = @($driveOutput | Where-Object { [int]$_.PartitionsOnDisk -gt 1 })
if ($multiPartDisks.Count -gt 0) {
  $diskNums = @($multiPartDisks | ForEach-Object { $_.DiskNumber } | Sort-Object -Unique)
  Write-Host "NOTE: Multi-partition disk(s) detected. Multiple volumes share a physical disk." -ForegroundColor Yellow
  foreach ($dn in $diskNums) {
    $letters = ($multiPartDisks | Where-Object { $_.DiskNumber -eq $dn } |
      ForEach-Object { $_.Drive }) -join ', '
    Write-Host "  Disk ${dn}: drives $letters" -ForegroundColor Yellow
  }
  Write-Host ""
}

if ($mountPoints.Count -gt 0) {
  Write-Host "WARNING: Mount point volume(s) detected. These are NOT in the CSV and require manual setup." -ForegroundColor Yellow
  foreach ($mp in $mountPoints) {
    Write-Host "  Disk $($mp.DiskNumber): mounted at $($mp.MountPath) ($($mp.SizeMB) MB)" -ForegroundColor Yellow
  }
  Write-Host ""
}

Write-Host "Output saved to: $OutputPath" -ForegroundColor Green
