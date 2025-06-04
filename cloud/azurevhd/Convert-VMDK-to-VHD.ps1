<#
.SYNOPSIS
This script converts a VMDK to a VHD using qemu-img.

.DESCRIPTION
This script converts a VMDK to a VHD using qemu-img.

For the VMDK, there should be two files: a '.vmdk' and '-flat.vmdk'.
'.vmdk' is the descriptor file while '-flat.vmdk' contains the data.
The qemu-img tool for conversion should be pointed at the '.vmdk' descriptor file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/28/25

Requirements:
- qemu-img: for converting the .vmdk to a .vhd - https://www.qemu.org/download/
- Windows VM with Hyper-V PowerShell tools installed - used for 'Resize-VHD':
** Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell

Optional components:
- (optional) Full Hyper-V: Can use to create a Hyper-V VM to validate that the converted disk is bootable.
- (optional) Azure VM agent on the source VM: for easier troubleshooting in Azure - https://github.com/Azure/WindowsVMAgent

Notes on conversion:
The boot volume is exported from Rubrik as a vmdk.
The volume has two files: .vmdk which is the descriptor, and -flat.vmdk that contains the data.

There are two partitioning schemes for the boot volume:
1. MBR - Instantiated as an Azure Gen 1 Managed Disk
2. GPT - Instantiated as an Azure Gen 2 Managed Disk

The conversion process to a VHD is the same for both MBR and GPT but when
the Azure Managed Disk is created it will need to be specified as a Gen 2
if the partition type is MBR.

'qemu-img' is an open source tool that is used to convert the vmdk to a vhd.
The conversion needs to be done with the 'fixed' option to allocate all bytes to the vhd.

Notes on validating the converted vhd:
You can validate the vhd with a few methods to ensure it will work in Azure.
It's easiest to perform these checks on a local Windows host w/Hyper-V role installed.
1. Disk Management - "Attach" the VHD and verify that you can browse the files.
    If it's a boot volume you should also see a "System Partition" of 100 - 500 MB in size.
    If the "System Partition" is not there then the conversion may not have been successful
    or you will need to expand the vhd and add a boot partition.
2. Hyper-V - If the vhd can be spun up in Hyper-V then it should work in Azure.
    Create a Hyper-V VM and attach the vhd as the boot disk. Verify that it can boot.
    For MBR partitions, create Hyper-V Gen 1 VM using the VHD.
    For GPT partitions, Hyper-V Gen 2 VMs require VHDX. You can convert the VMDK
    to VHDX to check how it's working, but will need to convert to VHD to upload
    to Azure. Azure only supports VHD and not VHDX.

.EXAMPLE
./Convert-VMDK-To-VHD.ps1 -sourceVMDK <source vmdk descriptor file>
  -targetVHD <target vhd filename>

#>


param (
  [CmdletBinding()]
  # Source VMDK - descriptor file, not the -flat.vmdk file
  [Parameter(Mandatory=$true)]
  [string]$sourceVMDK = '',
  # Target VHD - path and filename
  [Parameter(Mandatory=$true)]
  [string]$targetVHD = ''
)

# Specify the location of the qemu-img.exe tool
$qemuPath = "C:\Program Files\qemu\qemu-img.exe"

# Testing variables
# $sourceVMDK = "C:\images\rp-fileserv-01.vmdk"
# $targetVHD = "e:\rubrik-c-drive.vhd"

# $sourceFilename = Split-Path -Path $sourceVMDK -Leaf
# $targetVHDFilename = $sourceFilename -replace '\.vmdk$', '.vhd'
# $targetVHD = $targetDir + $targetVHDFileName
Write-Host "Source VMDK: $sourceVMDK" -foregroundcolor green
# Write-Host "The source VMDK filename is: $sourceFilename" -foregroundcolor green
Write-Host "Target VHD: $targetVHD" -foregroundcolor green

# Within the '.vmdk' descriptor file, there is a line for Extend description:
# Extent description
# RW 125829120 VMFS "<.vmdk file>" 0
# We need to change 'VMFS' to 'FLAT' for the qemu-img tool to conver properly
Write-Host "Updating the vmdk descriptor file from VMFS to FLAT" -foregroundcolor green
$vmdkDescriptor = Get-Content -Path $sourceVMDK

# Search for the Line and Replace 'VMFS' with 'FLAT'
$vmdkDescriptor = $vmdkDescriptor | ForEach-Object {
  if ($_ -match 'RW\s+\d+\s+VMFS') {
      # Locate the first occurrence of 'VMDK' in a case-sensitive manner
      $Index = $_.IndexOf('VMFS')
      # Ensure the index is valid before proceeding
      if ($Index -ge 0) {
          # Replace ONLY the first 'VMDK' instance with 'FLAT'
          $ModifiedLine = $_.Substring(0, $Index) + 'FLAT' + $_.Substring($Index + 4)
          $ModifiedLine
      } else {
          $_
      }
  } else {
      # Leave lines that don't match unchanged
      $_
  }
}
# Write the Modified Content Back to the File
Set-Content -Path $sourceVMDK -Value $vmdkDescriptor

# Convert vmdk to a vhd (vpc) with 'fixed' format that allocates all space
Write-Host "Converting the vmdk to vhd using qemu-img" -foregroundcolor green
& $qemuPath convert -f "vmdk" -O "vpc" -o "subformat=fixed" $sourceVMDK $targetVHD

# Even after conversion, Windows might mark the VHD as sparse
# Ensure that the VHD does not have the 'sparse' attribute
Write-Host "Checking vhd attributes and ensuring that it is marked as sparse" -foregroundcolor green
Get-Item $targetVHD | select-object Attributes
& fsutil sparse setflag $targetVHD 0
Get-Item $targetVHD | select-object Attributes

# Ensure that the VHD is aligned to MB and if not, re-size the VHD
Write-Host "Checking converted vhd disk alignment" -foregroundcolor green
$currentSize = (Get-Item $targetVHD).Length

# What the aligned size to 1 MB should be
$alignedSize = [math]::Ceiling($currentSize / 1048576) * 1048576

Get-VHD -Path $targetVHD
Write-Host "Current Size (bytes): $currentSize"
Write-Host "Aligned Size (bytes): $alignedSize"

# If VHD is not aligned to 1 MB then re-size it
if ($currentSize -ne $alignedSize) {
  Write-Host "Re-aligning vhd to 1 MB" -foregroundcolor green
  Resize-VHD -Path $targetVHD -SizeBytes $alignedSize
  Get-VHD -Path $targetVHD
  $currentSize = (Get-Item $targetVHD).Length
  Write-Host "Current Size (bytes): $currentSize"
}

Write-Host "Finished converting vhd: $targetVHD"
