<#
.SYNOPSIS
Captures drive configuration from a Windows VM to a CSV file.

.DESCRIPTION
Enumerates all volumes with drive letters on the local machine and captures
disk, partition, and volume details to a CSV. The output CSV is consumed by
Initialize-VMDrives.ps1 on the target VM after migration to recreate drive
letters, formatting, and volume labels.

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

$volLookup = @{}
Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
  $volLookup[$_.DriveLetter[0]] = $_
}

$systemDriveLetter = $env:SystemDrive[0]

$driveOutput = @()

$volumes = Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter

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
    ServerName          = $env:COMPUTERNAME
    Drive               = $letter
    DriveType           = $vol.FileSystemLabel
    TotalCapacityMB     = [math]::Round($vol.Size / 1MB)
    UsedSpaceMB         = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1MB)
    TotalCapacityBytes  = $vol.Size
    FileSystem          = $vol.FileSystemType
    AllocationUnitSizeKB = $allocUnitKB
    PartitionStyle      = $partStyle
    DiskNumber          = $diskNumber
    BusType             = $busType
    ScsiTarget          = $scsiTarget
    DiskSizeGB          = $diskSizeGB
    IsSystem            = $isSystem
    IsBoot              = $isBoot
  }
}

$driveOutput | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host ""
Write-Host "Drive info for $($env:COMPUTERNAME) ($($driveOutput.Count) volumes):" -ForegroundColor Green
$driveOutput | Format-Table Drive, DriveType, TotalCapacityMB, FileSystem,
  AllocationUnitSizeKB, PartitionStyle, DiskNumber, IsBoot -AutoSize
Write-Host "Output saved to: $OutputPath" -ForegroundColor Green
