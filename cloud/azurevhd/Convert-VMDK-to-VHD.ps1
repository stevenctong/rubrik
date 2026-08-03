<#
.SYNOPSIS
This script converts one or more VMDKs to fixed VHD format using qemu-img.

.DESCRIPTION
This script converts one or more VMDKs to fixed VHD format using qemu-img for
direct upload to Azure managed disks. VHD has a hard 2 TB size limit -- disks
larger than 2 TB are skipped with a warning.

Supports two input modes:
- Single-file mode: converts one VMDK by specifying -sourceVMDK and -targetVHD.
- Directory mode: converts all VMDK descriptor files in -sourceDir automatically.

For the VMDK, there should be two files: a '.vmdk' and '-flat.vmdk'.
'.vmdk' is the descriptor file while '-flat.vmdk' contains the data.
The qemu-img tool for conversion should be pointed at the '.vmdk' descriptor file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/28/25
Updated: 8/3/26

References:
- Azure VHD upload: https://learn.microsoft.com/en-us/azure/virtual-machines/windows/disks-upload-vhd-to-managed-disk-powershell

Requirements:
- qemu-img: for converting the .vmdk to a .vhd - https://www.qemu.org/download/
- Hyper-V PowerShell module: for VHD alignment (Resize-VHD) - install via Enable-WindowsOptionalFeature

Optional components:
- (optional) Hyper-V VM: Can use to create a Hyper-V VM to validate that the converted disk is bootable.
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
Used in single-file mode. Mutually exclusive with -sourceDir.

.PARAMETER targetVHD
Path and filename for the output VHD file.
Used in single-file mode.

.PARAMETER sourceDir
Path to a directory containing downloaded VMDK files. The script finds all
.vmdk descriptor files (excluding -flat.vmdk data files) and converts each one.
Mutually exclusive with -sourceVMDK.

.PARAMETER targetDir
Output directory for converted files in directory mode.
Defaults to the same directory as -sourceDir.

.PARAMETER qemuPath
Path to the qemu-img.exe tool. Defaults to 'C:\Program Files\qemu\qemu-img.exe'.

.PARAMETER reportFile
Optional path to write a JSON conversion report. Contains per-disk detection
results: source/target filenames, partition style (MBR/GPT), boot disk
detection, and virtual size. Used by Start-VMConversion.ps1 orchestrator.

.PARAMETER vmName
Optional VM name used as a log prefix for output lines. When set, all
Write-Host / Write-Error output is prefixed with [vmName] so parallel
orchestrator output is traceable.

.EXAMPLE
./Convert-VMDK-To-VHD.ps1 -sourceVMDK <source vmdk descriptor file>
  -targetVHD <target vhd filename> [-qemuPath <path to qemu-img.exe>]
Converts a single VMDK to VHD.

.EXAMPLE
./Convert-VMDK-To-VHD.ps1 -sourceDir <directory with downloaded VMDKs>
  [-targetDir <output directory>]
Finds all VMDK descriptor files in the directory and converts each to VHD.

#>

[CmdletBinding()]
param (
  # Source VMDK - descriptor file, not the -flat.vmdk file
  [Parameter(Mandatory=$false)]
  [string]$sourceVMDK = '',
  # Target VHD - path and filename
  [Parameter(Mandatory=$false)]
  [string]$targetVHD = '',
  # Source directory containing downloaded VMDK files
  [Parameter(Mandatory=$false)]
  [string]$sourceDir = '',
  # Output directory for converted files (defaults to sourceDir)
  [Parameter(Mandatory=$false)]
  [string]$targetDir = '',
  # Path to qemu-img.exe
  [Parameter(Mandatory=$false)]
  [string]$qemuPath = 'C:\Program Files\qemu\qemu-img.exe',
  # Optional path to write a JSON conversion report
  [Parameter(Mandatory=$false)]
  [string]$reportFile = '',
  # Optional VM name for log prefix (used by orchestrator)
  [Parameter(Mandatory=$false)]
  [string]$vmName = ''
)

$logPrefix = if ($vmName -ne '') { "[$vmName] " } else { '' }

$convertStartTime = Get-Date
Write-Host "${logPrefix}Conversion started: $($convertStartTime.ToString('M/d/yy h:mm:ss tt'))" -ForegroundColor Cyan

$dirMode = -not [string]::IsNullOrEmpty($sourceDir)
$singleMode = -not [string]::IsNullOrEmpty($sourceVMDK)

if ($dirMode -and $singleMode) {
  Write-Error "${logPrefix}Cannot specify both -sourceVMDK and -sourceDir. Use one mode or the other."
  exit
}

if (-not $dirMode -and -not $singleMode) {
  Write-Host ""
  Write-Host "Usage (single-file mode): ./Convert-VMDK-To-VHD.ps1" -ForegroundColor Cyan
  Write-Host "  -sourceVMDK <path to vmdk descriptor file>"
  Write-Host "  -targetVHD <path for output file>"
  Write-Host "  [-qemuPath <path to qemu-img.exe>]"
  Write-Host ""
  Write-Host "Usage (directory mode): ./Convert-VMDK-To-VHD.ps1" -ForegroundColor Cyan
  Write-Host "  -sourceDir <directory with downloaded VMDKs>"
  Write-Host "  [-targetDir <output directory>]"
  Write-Host ""
  Write-Host "Note: VHD format has a 2 TB size limit. Disks larger than 2 TB are skipped." -ForegroundColor Yellow
  exit
}

if ($singleMode -and [string]::IsNullOrEmpty($targetVHD)) {
  Write-Error "Single-file mode requires -targetVHD."
  exit
}

# Build the list of files to convert
$conversionList = @()

if ($dirMode) {
  if (-not (Test-Path $sourceDir -PathType Container)) {
    Write-Error "${logPrefix}Source directory not found: $sourceDir"
    exit
  }
  if ([string]::IsNullOrEmpty($targetDir)) {
    $targetDir = $sourceDir
  }
  if (-not (Test-Path $targetDir -PathType Container)) {
    Write-Error "${logPrefix}Target directory not found: $targetDir"
    exit
  }

  $descriptorFiles = @(Get-ChildItem -Path $sourceDir -Filter '*.vmdk' |
    Where-Object { $_.Name -notmatch '-flat\.vmdk$' })

  if ($descriptorFiles.Count -eq 0) {
    Write-Error "${logPrefix}No VMDK descriptor files found in: $sourceDir"
    exit
  }

  Write-Host "${logPrefix}Found $($descriptorFiles.Count) VMDK descriptor file(s) in: $sourceDir" -ForegroundColor Cyan
  foreach ($df in $descriptorFiles) {
    $outName = $df.BaseName + '.vhd'
    $outPath = Join-Path -Path $targetDir -ChildPath $outName
    $conversionList += [PSCustomObject]@{
      Source = $df.FullName
      Target = $outPath
    }
    Write-Host "${logPrefix}  $($df.Name)"
  }
  Write-Host ""
} else {
  $conversionList += [PSCustomObject]@{
    Source = $sourceVMDK
    Target = $targetVHD
  }
}

$successCount = 0
$failCount = 0
$skipCount = 0
$conversionResults = @()

for ($idx = 0; $idx -lt $conversionList.Count; $idx++) {
  $item = $conversionList[$idx]
  $currentSource = $item.Source
  $currentTarget = $item.Target

  if ($conversionList.Count -gt 1) {
    Write-Host "${logPrefix}======================================================================" -ForegroundColor Cyan
    Write-Host "${logPrefix}[$($idx + 1)/$($conversionList.Count)] Converting: $(Split-Path $currentSource -Leaf)" -ForegroundColor Cyan
    Write-Host "${logPrefix}======================================================================" -ForegroundColor Cyan
  }

  Write-Host "${logPrefix}Source VMDK: $currentSource" -ForegroundColor Green

  # Within the '.vmdk' descriptor file, there is a line for Extend description:
  # Extent description
  # RW 125829120 VMFS "<.vmdk file>" 0
  # We need to change 'VMFS' to 'FLAT' for the qemu-img tool to convert properly
  Write-Host "${logPrefix}Updating the vmdk descriptor file from VMFS to FLAT" -ForegroundColor Green
  $vmdkDescriptor = Get-Content -Path $currentSource

  # Replace 'VMFS' with 'FLAT' in the extent description lines
  $vmdkDescriptor = $vmdkDescriptor | ForEach-Object {
    if ($_ -match 'RW\s+\d+\s+VMFS') {
      $_ -replace 'VMFS', 'FLAT'
    } else {
      $_
    }
  }
  Set-Content -Path $currentSource -Value $vmdkDescriptor

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
    $vmdkDir = Split-Path -Path $currentSource -Parent
    if ([string]::IsNullOrEmpty($vmdkDir)) { $vmdkDir = '.' }
    $flatFilePath = Join-Path -Path $vmdkDir -ChildPath $flatFileName

    if (Test-Path $flatFilePath) {
      Write-Host "${logPrefix}Attempting to detect partition style from: $flatFileName" -ForegroundColor Green
      try {
        $stream = [System.IO.File]::OpenRead($flatFilePath)
        $buffer = New-Object byte[] 2048
        $stream.Read($buffer, 0, 2048) | Out-Null
        $stream.Close()

        # GPT disks have "EFI PART" signature at byte offset 512 (LBA 1)
        $gptSig = [System.Text.Encoding]::ASCII.GetString($buffer, 512, 8)
        if ($gptSig -eq 'EFI PART') {
          $partitionStyle = 'GPT'
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
          for ($i = 0; $i -lt 4; $i++) {
            if ($buffer[446 + ($i * 16)] -eq 0x80) { $isBootDisk = $true; break }
          }
        }
      } catch {
        Write-Host "${logPrefix}WARNING: Could not read flat VMDK file: $_" -ForegroundColor Yellow
      }
    } else {
      Write-Host "${logPrefix}WARNING: Flat VMDK file not found: $flatFilePath" -ForegroundColor Yellow
    }
  } else {
    Write-Host "${logPrefix}WARNING: Could not determine flat VMDK filename from descriptor" -ForegroundColor Yellow
  }

  if ($partitionStyle -ne 'Unknown') {
    Write-Host "${logPrefix}Partition style: $partitionStyle" -ForegroundColor Green
    if ($isBootDisk) {
      Write-Host "${logPrefix}Boot disk: Yes (system partition detected)" -ForegroundColor Green
    } else {
      Write-Host "${logPrefix}Boot disk: Not detected (likely a data disk)" -ForegroundColor Green
    }
  } else {
    Write-Host "${logPrefix}Partition style: Could not be determined" -ForegroundColor Yellow
  }

  # Determine virtual disk size from the descriptor's sector count
  $virtualSizeBytes = [long]0
  $vmdkDescriptor | ForEach-Object {
    if ($_ -match '^RW\s+(\d+)\s+') {
      $virtualSizeBytes += [long]$Matches[1] * 512
    }
  }
  if ($virtualSizeBytes -eq 0) {
    Write-Host "${logPrefix}WARNING: Could not determine virtual disk size from descriptor" -ForegroundColor Yellow
  } else {
    Write-Host "${logPrefix}Virtual disk size: $([math]::Round($virtualSizeBytes / 1GB, 2)) GB" -ForegroundColor Green
  }

  # VHD format has a hard 2 TB limit -- skip disks that exceed it
  $twoTBThreshold = [long]2 * 1024 * 1024 * 1024 * 1024
  if ($virtualSizeBytes -gt $twoTBThreshold) {
    Write-Host "${logPrefix}WARNING: Skipping disk - size exceeds 2 TB limit ($([math]::Round($virtualSizeBytes / 1TB, 2)) TB). VHD format only supports disks 2 TB and under." -ForegroundColor Yellow
    $skipCount++
    continue
  }

  Write-Host "${logPrefix}Target: $currentTarget" -ForegroundColor Green

  # Convert vmdk to vhd using qemu-img
  Write-Host "${logPrefix}Converting the vmdk to VHD using qemu-img" -ForegroundColor Green
  $qemuOutput = & $qemuPath convert -f "vmdk" -O "vpc" -o "subformat=fixed" $currentSource $currentTarget 2>&1
  $qemuOutput | ForEach-Object { Write-Host "${logPrefix}  $_" }

  if ($LASTEXITCODE -ne 0) {
    Write-Host "${logPrefix}ERROR: qemu-img conversion failed with exit code $LASTEXITCODE" -ForegroundColor Red
    $failCount++
    continue
  }

  # Even after conversion, Windows might mark the file as sparse
  Write-Host "${logPrefix}Checking file attributes and ensuring sparse flag is cleared" -ForegroundColor Green
  $attrBefore = Get-Item $currentTarget | Select-Object Attributes
  Write-Host "${logPrefix}  Attributes: $($attrBefore.Attributes)"
  $fsutilOutput = & fsutil sparse setflag $currentTarget 0 2>&1
  $fsutilOutput | ForEach-Object { Write-Host "${logPrefix}  $_" }
  $attrAfter = Get-Item $currentTarget | Select-Object Attributes
  Write-Host "${logPrefix}  Attributes: $($attrAfter.Attributes)"

  # Align VHD to 1 MB boundary (Azure requires whole-MB virtual sizes)
  Write-Host "${logPrefix}Checking VHD disk alignment" -ForegroundColor Green
  $currentSize = (Get-Item $currentTarget).Length
  $alignedSize = [math]::Ceiling($currentSize / 1048576) * 1048576

  $vhdInfo = Get-VHD -Path $currentTarget
  Write-Host "${logPrefix}  VHD size: $($vhdInfo.Size) bytes, file size: $currentSize bytes"
  Write-Host "${logPrefix}  Aligned size: $alignedSize bytes"

  if ($currentSize -ne $alignedSize) {
    Write-Host "${logPrefix}Resizing VHD to align to 1 MB boundary" -ForegroundColor Green
    try {
      Resize-VHD -Path $currentTarget -SizeBytes $alignedSize -ErrorAction Stop
    } catch {
      Write-Host "${logPrefix}ERROR: Resize-VHD failed: $($_.Exception.Message)" -ForegroundColor Red
      $failCount++
      continue
    }
    $vhdInfo = Get-VHD -Path $currentTarget
    $currentSize = (Get-Item $currentTarget).Length
    Write-Host "${logPrefix}  Resized: VHD size: $($vhdInfo.Size) bytes, file size: $currentSize bytes"
  } else {
    Write-Host "${logPrefix}VHD already aligned to 1 MB" -ForegroundColor Green
  }

  Write-Host "${logPrefix}Finished converting: $currentTarget" -ForegroundColor Green
  $successCount++

  $conversionResults += [PSCustomObject]@{
    sourceFile      = Split-Path $currentSource -Leaf
    targetFile      = Split-Path $currentTarget -Leaf
    partitionStyle  = $partitionStyle
    isBootDisk      = $isBootDisk
    virtualSizeBytes = $virtualSizeBytes
  }

  if ($conversionList.Count -gt 1) {
    Write-Host ""
  }
}

if ($conversionList.Count -gt 1) {
  Write-Host "${logPrefix}======================================================================" -ForegroundColor Cyan
  if ($failCount -eq 0 -and $skipCount -eq 0) {
    Write-Host "${logPrefix}All $successCount file(s) converted successfully." -ForegroundColor Green
  } else {
    $summaryParts = @("$successCount converted")
    if ($skipCount -gt 0) { $summaryParts += "$skipCount skipped (>2 TB)" }
    if ($failCount -gt 0) { $summaryParts += "$failCount failed" }
    $summaryColor = if ($failCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "${logPrefix}$($summaryParts -join ', ')" -ForegroundColor $summaryColor
  }
  Write-Host "${logPrefix}======================================================================" -ForegroundColor Cyan
}

if ($reportFile -ne '' -and $conversionResults.Count -gt 0) {
  $conversionResults | ConvertTo-Json -Depth 5 | Set-Content -Path $reportFile
  Write-Host "${logPrefix}Conversion report written to: $reportFile" -ForegroundColor Green
}

$convertEndTime = Get-Date
$convertElapsed = $convertEndTime - $convertStartTime
Write-Host "${logPrefix}Conversion completed: $($convertEndTime.ToString('M/d/yy h:mm:ss tt')) (elapsed: $([math]::Round($convertElapsed.TotalMinutes, 1)) min)" -ForegroundColor Cyan
