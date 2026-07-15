<#
.SYNOPSIS
This script converts a VMDK to a VHD (or VHDX for disks larger than 2 TB) using qemu-img.

.DESCRIPTION
This script converts a VMDK to a VHD (or VHDX for disks larger than 2 TB) using qemu-img.
The VHD format has a hard 2 TB size limit. For VMDKs exceeding 2 TB, the script
automatically converts to VHDX format and warns about Azure upload requirements.

For the VMDK, there should be two files: a '.vmdk' and '-flat.vmdk'.
'.vmdk' is the descriptor file while '-flat.vmdk' contains the data.
The qemu-img tool for conversion should be pointed at the '.vmdk' descriptor file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/28/25
Updated: 7/15/26

References:
- Azure VHD/VHDX upload: https://learn.microsoft.com/en-us/azure/virtual-machines/windows/disks-upload-vhd-to-managed-disk-powershell

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
if the partition type is GPT.

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
    to Azure. Azure supports VHD for all disk SKUs, and VHDX for Premium SSD v2
    and Ultra Disk SKUs only.

.PARAMETER sourceVMDK
Path to the VMDK descriptor file (not the -flat.vmdk data file).

.PARAMETER targetVHD
Path and filename for the output VHD (or VHDX for disks larger than 2 TB).

.PARAMETER qemuPath
Path to the qemu-img.exe tool. Defaults to 'C:\Program Files\qemu\qemu-img.exe'.

.EXAMPLE
./Convert-VMDK-To-VHD.ps1 -sourceVMDK <source vmdk descriptor file>
  -targetVHD <target vhd filename> [-qemuPath <path to qemu-img.exe>]
For disks larger than 2 TB, the script converts to VHDX and updates the target extension.

#>

[CmdletBinding()]
param (
  # Source VMDK - descriptor file, not the -flat.vmdk file
  [Parameter(Mandatory=$true)]
  [string]$sourceVMDK = '',
  # Target VHD - path and filename
  [Parameter(Mandatory=$true)]
  [string]$targetVHD = '',
  # Path to qemu-img.exe
  [Parameter(Mandatory=$false)]
  [string]$qemuPath = 'C:\Program Files\qemu\qemu-img.exe'
)

Write-Host "Source VMDK: $sourceVMDK" -foregroundcolor green

# Within the '.vmdk' descriptor file, there is a line for Extend description:
# Extent description
# RW 125829120 VMFS "<.vmdk file>" 0
# We need to change 'VMFS' to 'FLAT' for the qemu-img tool to conver properly
Write-Host "Updating the vmdk descriptor file from VMFS to FLAT" -foregroundcolor green
$vmdkDescriptor = Get-Content -Path $sourceVMDK

# Replace 'VMFS' with 'FLAT' in the extent description lines
$vmdkDescriptor = $vmdkDescriptor | ForEach-Object {
  if ($_ -match 'RW\s+\d+\s+VMFS') {
    $_ -replace 'VMFS', 'FLAT'
  } else {
    $_
  }
}
# Write the Modified Content Back to the File
Set-Content -Path $sourceVMDK -Value $vmdkDescriptor

# Detect partition style (MBR/GPT) by reading raw bytes from the flat VMDK
$flatFileName = ''
foreach ($line in $vmdkDescriptor) {
  if ($line -match 'RW\s+\d+\s+FLAT\s+"([^"]+)"') {
    $flatFileName = $Matches[1]
    break
  }
}

$partitionStyle = 'Unknown'
$isBootDisk = $false

if ($flatFileName -ne '') {
  $vmdkDir = Split-Path -Path $sourceVMDK -Parent
  if ([string]::IsNullOrEmpty($vmdkDir)) { $vmdkDir = '.' }
  $flatFilePath = Join-Path -Path $vmdkDir -ChildPath $flatFileName

  if (Test-Path $flatFilePath) {
    Write-Host "Attempting to detect partition style from: $flatFileName" -foregroundcolor green
    try {
      $stream = [System.IO.File]::OpenRead($flatFilePath)
      $buffer = New-Object byte[] 2048
      $stream.Read($buffer, 0, 2048) | Out-Null
      $stream.Close()

      # GPT disks have "EFI PART" signature at byte offset 512 (LBA 1)
      $gptSig = [System.Text.Encoding]::ASCII.GetString($buffer, 512, 8)
      if ($gptSig -eq 'EFI PART') {
        $partitionStyle = 'GPT'
        # Check first 8 GPT partition entries (starting at byte 1024, 128 bytes each)
        # for EFI System Partition type GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
        $espGuid = [byte[]]@(0x28,0x73,0x2A,0xC1,0x1F,0xF8,0xD2,0x11,
                             0xBA,0x4B,0x00,0xA0,0xC9,0x3E,0xC9,0x3B)
        for ($i = 0; $i -lt 8; $i++) {
          $offset = 1024 + ($i * 128)
          $match = $true
          for ($j = 0; $j -lt 16; $j++) {
            if ($buffer[$offset + $j] -ne $espGuid[$j]) { $match = $false; break }
          }
          if ($match) { $isBootDisk = $true; break }
        }
      } elseif ($buffer[510] -eq 0x55 -and $buffer[511] -eq 0xAA) {
        $partitionStyle = 'MBR'
        # Check 4 MBR partition entries (bytes 446-509, 16 bytes each)
        # First byte 0x80 = active/bootable partition
        for ($i = 0; $i -lt 4; $i++) {
          if ($buffer[446 + ($i * 16)] -eq 0x80) { $isBootDisk = $true; break }
        }
      }
    } catch {
      Write-Host "WARNING: Could not read flat VMDK file: $_" -foregroundcolor yellow
    }
  } else {
    Write-Host "WARNING: Flat VMDK file not found: $flatFilePath" -foregroundcolor yellow
  }
} else {
  Write-Host "WARNING: Could not determine flat VMDK filename from descriptor" -foregroundcolor yellow
}

if ($partitionStyle -ne 'Unknown') {
  Write-Host "Partition style: $partitionStyle" -foregroundcolor green
  if ($isBootDisk) {
    Write-Host "Boot disk: Yes (system partition detected)" -foregroundcolor green
  } else {
    Write-Host "Boot disk: Not detected (likely a data disk)" -foregroundcolor green
  }
} else {
  Write-Host "Partition style: Could not be determined" -foregroundcolor yellow
}

# Determine virtual disk size from the descriptor's sector count
$virtualSizeBytes = [long]0
$vmdkDescriptor | ForEach-Object {
  if ($_ -match '^RW\s+(\d+)\s+') {
    $virtualSizeBytes += [long]$Matches[1] * 512
  }
}
if ($virtualSizeBytes -eq 0) {
  Write-Host "WARNING: Could not determine virtual disk size from descriptor, assuming <= 2 TB" -foregroundcolor yellow
} else {
  Write-Host "Virtual disk size: $([math]::Round($virtualSizeBytes / 1GB, 2)) GB" -foregroundcolor green
}

# VHD format has a hard 2 TB limit, use VHDX for larger disks
$twoTBThreshold = [long]2 * 1024 * 1024 * 1024 * 1024
$isLargeDisk = $virtualSizeBytes -gt $twoTBThreshold

if ($isLargeDisk) {
  Write-Host ""
  Write-Host "======================================================================" -foregroundcolor yellow
  Write-Host "WARNING: Disk size exceeds 2 TB ($([math]::Round($virtualSizeBytes / 1TB, 2)) TB)" -foregroundcolor yellow
  Write-Host "The VHD format has a hard 2 TB size limit." -foregroundcolor yellow
  Write-Host "Converting to VHDX format instead." -foregroundcolor yellow
  Write-Host "" -foregroundcolor yellow
  Write-Host "Azure VHDX upload requirements:" -foregroundcolor yellow
  Write-Host "  - VHDX uploads only supported on Premium SSD v2 or Ultra Disk SKUs" -foregroundcolor yellow
  Write-Host "  - Must use AzCopy for upload (Add-AzVHD does not support these SKUs)" -foregroundcolor yellow
  Write-Host "  - Target managed disk must use -LogicalSectorSize 4096" -foregroundcolor yellow
  Write-Host "  - For OS disks, the source partition must be GPT (Gen 2)" -foregroundcolor yellow
  Write-Host "  - Azure expands the VHDX to the next 256 MiB alignment on upload" -foregroundcolor yellow
  Write-Host "======================================================================" -foregroundcolor yellow
  Write-Host ""

  # Update target extension to .vhdx if user specified .vhd
  if ($targetVHD -match '\.vhd$') {
    $targetVHD = $targetVHD + 'x'
  }
}

Write-Host "Target: $targetVHD" -foregroundcolor green

# Convert vmdk using qemu-img
if ($isLargeDisk) {
  Write-Host "Converting the vmdk to vhdx using qemu-img" -foregroundcolor green
  & $qemuPath convert -f "vmdk" -O "vhdx" -o "subformat=fixed" $sourceVMDK $targetVHD
} else {
  Write-Host "Converting the vmdk to vhd using qemu-img" -foregroundcolor green
  & $qemuPath convert -f "vmdk" -O "vpc" -o "subformat=fixed" $sourceVMDK $targetVHD
}

if ($LASTEXITCODE -ne 0) {
  Write-Host "ERROR: qemu-img conversion failed with exit code $LASTEXITCODE" -foregroundcolor red
  exit 1
}

# Even after conversion, Windows might mark the file as sparse
Write-Host "Checking file attributes and ensuring sparse flag is cleared" -foregroundcolor green
Get-Item $targetVHD | Select-Object Attributes
& fsutil sparse setflag $targetVHD 0
Get-Item $targetVHD | Select-Object Attributes

# For VHD only: ensure alignment to 1 MB and resize if needed
# VHDX does not need this - Azure aligns VHDX to 256 MiB on upload
if (-not $isLargeDisk) {
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
}

Write-Host "Finished converting: $targetVHD"
