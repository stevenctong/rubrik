<#
.SYNOPSIS
Parses and summarize VMtools storage info and outputs the formatted results to a CSV.

.DESCRIPTION
The Parse-VMtools.ps1 script parses and summarizes VMtools storage info and outputs the formatted results to a CSV.
The script requires the following parameters:

-dir <direcotry_with_VMtools_files : This directory should contain the following files:
** RVTools_tabvInfo.csv
** RVTools_tabvDisk.csv
** RVTools_tabvPartition.csv

-output <filename.csv> : CSV file to output the results to. If file exists results will be appended.

If you have multiple RVtools that you want to combine together you can re-run the script to the same output file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/6/21

.EXAMPLE
./Parse-VMTools.ps1 -dir <directory_with_VMtools_files> -output <filename.csv>
Takes a directory with VMtools files as input and specify a CSV file to output the results to.

#>

param (
  [CmdletBinding()]

  # Input directory of VMTools results, should contain: RVTools_tabvInfo.csv, RVTools_tabvDisk.csv, RVTools_tabvPartition.csv
  [Parameter(Mandatory=$true)]
  [string]$dir = '',

  # CSV file to output the results to. If file exists, results will be appended.
  [Parameter(Mandatory=$false)]
  [string]$output = ''
)

# RVtool filenames
$vInfoFile = 'RVTools_tabvInfo.csv'
$vDiskFile = 'RVTools_tabvDisk.csv'
$vPartitionFile = 'RVTools_tabvPartition.csv'

# Check that the RVtools CSV files are present
if ( ((Test-Path -Path $dir/$vInfoFile) -and (Test-Path -Path $dir/$vDiskFile) -and
      (Test-Path -Path $dir/$vPartitionFile) ) -eq $false)
{
  Write-Error "One of the following not found:"
  Write-Error "$dir/$vInfoFile"
  Write-Error "$dir/$vDiskFile"
  Write-Error "$dir/$vPartitionFile"
  exit
}

Write-Host "Importing RVtools files found in directory: $dir" -foregroundcolor green
$vInfo = Import-Csv -Path "$dir/$vInfoFile"
$vDisk = Import-Csv -Path "$dir/$vDiskFile"
$vPartition = Import-Csv -Path "$dir/$vPartitionFile"

# Check if the column names contain "MB" or "MiB" to reference the appropriate columns
if ($vPartition[0] | Get-Member -name 'Capacity MiB') {
  $unit = 'MiB'
} else {
  $unit = 'MB'
}

# Hash tables to store partition info
$vPartCapacity = @{}
$vPartConsumed = @{}

Write-Host "Adding up vPartition info" -foregroundcolor green
# Sum up the partition capacities for each VM
foreach ($part in $vPartition) {
    $vPartCapacity.($part.VM) += [int]$part."Capacity $unit"
    $vPartConsumed.($part.VM) += [int]$part."Consumed $unit"
}

# Hash tables to store disk info
$vDiskCapacity = @{}
$vDiskPersistentDisks = @{}
$vDiskPersistentCapacity = @{}
$vDiskIndependentDisks = @{}
$vDiskIndependentCapacity = @{}

Write-Host "Adding up vDisk info" -foregroundcolor green
# Sum up the disk capacities for each VM
foreach ($disk in $vDisk)
{
  $vDiskCapacity.($disk.VM) += [int]$disk."Capacity $unit"

  if ($disk.'Disk Mode' -eq 'persistent') {
    $vDiskPersistentDisks.($disk.VM) += 1
    $vDiskPersistentCapacity.($disk.VM) += [int]$disk."Capacity $unit"
    $vDiskIndependentDisks.($disk.VM) += 0
    $vDiskIndependentCapacity.($disk.VM) += 0
  } elseif ($disk.'Disk Mode' -eq 'independent_persistent') {
    $vDiskPersistentDisks.($disk.VM) += 0
    $vDiskPersistentCapacity.($disk.VM) += 0
    $vDiskIndependentDisks.($disk.VM) += 1
    $vDiskIndependentCapacity.($disk.VM) += [int]$disk."Capacity $unit"
  }
}

# Holds the list of formatted VM objects we want to output
$vmList = @()

Write-Host "Finalizing VM output" -foregroundcolor green
# Loop through each VM and create a formatted VM object
foreach ($vm in $vInfo) {
  $vmName = $vm.VM

  $vmObj = [PSCustomObject] @{
    "VM" = $vmName
    "blank1" = "blank1"
    "vPartition Consumed GB" = ([math]::round(($vPartConsumed.$vmName * 1.048576 / 1000), 2))
    "blank2" = "blank2"
    "vPartition Total Capacity GB" = ([math]::round(($vPartCapacity.$vmName * 1.048576 / 1000), 2))
    "(vDisk-vPartition) Capacity GB" = ([math]::round((($vDiskCapacity.$vmName - $vPartCapacity.$vmName) * 1.048576 / 1000), 2))
    "blank3" = "blank3"
    "vDisk Total Capacity GB" = ([math]::round(($vDiskCapacity.$vmName * 1.048576 / 1000), 2))
    "# Dep. Disks" = $vDiskPersistentDisks.$vmName
    "vDisk Persistent Capacity GB" = ([math]::round(($vDiskPersistentCapacity.$vmName * 1.048576 / 1000), 2))
    "# Ind. Disks" = $vDiskIndependentDisks.$vmName
    "vDisk Independent Capacity GB" = ([math]::round(($vDiskIndependentCapacity.$vmName * 1.048576 / 1000), 2))
    "blank4" = "blank4"
    "Provisioned GB" = ([math]::round(($vm."Provisioned $unit" * 1.048576 / 1000), 2))
    "In Use GB" = ([math]::round(($vm."In Use $unit" * 1.048576 / 1000), 2))
    "Unshared GB" = ([math]::round(($vm."Unshared $unit" * 1.048576 / 1000), 2))
    "Disks" = $vm.Disks
    "blank5" = "blank5"
    "Powerstate" = $vm.Powerstate
    "Template" = $vm.Template
    "CBT" = $vm.CBT
    "HW version" = $vm.'HW version'
    "EnableUUID" = $vm.EnableUUID
    "Annotation" = $vm.Annotation
    "DNS Name" = $vm.'DNS Name'
    "OS according to the configuration file" = $vm.'OS according to the configuration file'
    "OS according to the VMware Tools" = $vm.'OS according to the VMware Tools'
    "blank6" = "blank6"
    "Datacenter" = $vm.Datacenter
    "Cluster" = $vm.Cluster
    "Host" = $vm.Host
    "Resource pool" = $vm.'Resource pool'
    "Folder" = $vm.Folder
    "Path" = $vm.Path
    "blank7" = "blank7"
    "<Tag Category Name>" = $vm.'<Tag Category Name>'
    "<Tag 2 Category Name>" = $vm.'<Tag 2 Category Name>'
    "Guest state" = $vm.'Guest state'
    "Heartbeat" = $vm.Heartbeat
    "PowerOn" = $vm.PowerOn
    "Suspend time" = $vm.'Suspend time'
    "Change Version" = $vm.'Change Version'
    "CPUs" = $vm.CPUs
    "Memory" = $vm.Memory
    "NICs" = $vm.NICs
    "Network #1" = $vm.'Network #1'
    "Network #2" = $vm.'Network #2'
    "Network #3" = $vm.'Network #3'
    "Network #4" = $vm.'Network #4'
    "FT State" = $vm.'FT State'
    "Firmware" = $vm.Firmware
    "VM ID" = $vm.'VM ID'
    "VM UUID" = $vm.'VM UUID'
    "VI SDK Server type" = $vm.'VI SDK Server type'
    "VI SDK API Version" = $vm.'VI SDK API Version'
  }
  $vmList += $vmObj
}  # foreach ($vm in $vInfo)

$vPartTotal = [math]::round((($vmList.'vPartition Consumed GB' | Measure -sum).sum / 1000), 2)
$vGap = [math]::round((($vmList.'(vDisk-vPartition) Capacity GB' | Measure -sum).sum / 1000), 2)
$vDiskTotal = [math]::round((($vmList.'vDisk Total Capacity GB' | Measure -sum).sum / 1000), 2)
$vInfoTotal = [math]::round((($vmList."Provisioned $unit" | Measure -sum).sum / 1000), 2)

Write-Host ""
Write-Host "Total # of VMs found: $($vmList.count)" -foregroundcolor green
Write-Host "Total vPartition consumed capacity: $vPartTotal TB" -foregroundcolor green
Write-Host "Total (vPartition - vDisk) gap: $vGap TB" -foregroundcolor green
Write-Host "Total vDisk capacity: $vDiskTotal TB" -foregroundcolor green
Write-Host "Total vInfo provisioned capacity: $vInfoTotal TB" -foregroundcolor green
Write-Host ""

# Write out the results
if (Test-Path -Path $output) {
  Write-Host "Appending results to: $output" -foregroundcolor green
  ($vmList | ConvertTo-Csv) -replace "blank\d", "" | Select-Object -skip 1 | Out-File -Path $output -Append
} else {
  Write-Host "Writing results to: $output" -foregroundcolor green
  ($vmList | ConvertTo-Csv) -replace "blank\d", "" | Out-File -Path $output
}
