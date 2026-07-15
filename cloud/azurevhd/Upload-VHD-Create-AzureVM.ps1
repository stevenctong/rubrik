<#
.SYNOPSIS
This script uploads a VHD or VHDX to Azure and creates a managed disk from it.
For OS disks, it also creates a new VM. For data disks, it attaches to an existing VM.

.DESCRIPTION
This script uploads a VHD or VHDX to Azure and creates a managed disk from it.

For OS disks (-diskType OS): creates a new VM with the uploaded disk as the boot disk.
Supports both Gen 1 (MBR) and Gen 2 (GPT) managed disks via -hyperVGeneration.

For data disks (-diskType Data): uploads and creates the managed disk, then attaches
it to an existing VM specified by -attachToVM.

For VHD files, the script uploads to a Storage Account as a page blob and creates
a managed disk via Import.

For VHDX files, the script uses the Azure direct upload method: creates an empty
managed disk configured for upload, gets a write SAS URI, uploads via AzCopy,
then revokes the SAS. VHDX uploads are restricted to Premium SSD v2 or Ultra Disk
SKUs and require -LogicalSectorSize 4096.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/28/25
Updated: 7/15/26

References:
- Azure VHD/VHDX upload: https://learn.microsoft.com/en-us/azure/virtual-machines/windows/disks-upload-vhd-to-managed-disk-powershell

Requirements:
- Azure VM agent on the source VM: for easier troubleshooting in Azure - https://github.com/Azure/WindowsVMAgent
- For VHDX uploads: AzCopy v10 - https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10

Azure PowerShell Notes:
Get all Azure resource SKUs: $sku = Get-AzComputeResourceSku -location <region>

Notes on using the VHD/VHDX in Azure:
There are two upload methods:
1. Page blob upload: Upload VHD to a Storage Account, then create a Managed Disk via Import.
2. Direct upload: Create an empty Managed Disk, upload via AzCopy using a SAS URI.
You can either create a Managed Disk directly or a specialized or general image to
re-use it. A specialized image keeps the same copy of data while a generalized image
uses 'sysprep' to build a clean OS copy.

This script creates a Managed Disk directly from the VHD/VHDX and either creates
a new VM (OS disk) or attaches to an existing VM (data disk).

Some additional options for consideration:
- Size of VM
- Additional Managed Disk options - tier of disk, performance for v2 / Ultra, encryption

.PARAMETER configFile
Path to a PSD1 config file containing Azure environment variables (subscription,
resource group, storage account, networking, etc.). If provided, config values
override the hardcoded defaults in the VARIABLES section. See upload_config.psd1
for an example. Command-line parameters (vmName, sourceVHD, etc.) are not affected.

.PARAMETER vmName
Azure VM name. For OS disks, VM resource names (disk, NIC) are derived from this.
For data disks, used as the disk name prefix.

.PARAMETER sourceVHD
Path to the source VHD or VHDX file to upload.

.PARAMETER diskType
Whether the disk is an OS boot disk or a data disk. Valid values: 'OS', 'Data'.
Defaults to 'OS'. Data disks require -attachToVM.

.PARAMETER attachToVM
Name of the existing Azure VM to attach a data disk to. Required when -diskType is 'Data'.
The VM must be in the same resource group specified in the VARIABLES section.

.PARAMETER osType
OS type of the disk (OS disks only). Valid values: 'Windows', 'Linux'. Defaults to 'Windows'.

.PARAMETER hyperVGeneration
Hyper-V generation for the managed disk (OS disks only). Use 'V1' for MBR, 'V2' for GPT.
Defaults to 'V1'.

.PARAMETER vmSize
Azure VM size SKU (OS disks only). Defaults to 'Standard_E2_v5'.

.PARAMETER skuName
Managed disk SKU type. Defaults to 'StandardSSD_LRS'.
Options: Standard_LRS, Premium_LRS, Premium_ZRS, StandardSSD_LRS, StandardSSD_ZRS, PremiumV2_LRS, UltraSSD_LRS
Note: VHDX uploads require PremiumV2_LRS or UltraSSD_LRS.

.PARAMETER azcopyPath
Path to the AzCopy executable. Required for VHDX uploads or -alwaysUseAzCopy. Defaults to 'azcopy' (assumes on PATH).
Download AzCopy v10: https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10

.PARAMETER alwaysUseAzCopy
Switch to use the direct upload (AzCopy) path even for VHD files instead of the page blob
upload path. Useful for testing the direct upload path before consolidating.

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -vmName <VM Name> -sourceVHD <path to VHD file>
  [-osType Windows|Linux] [-hyperVGeneration V1|V2]
  [-vmSize <VM size>] [-skuName <disk SKU>]

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -vmName <VM Name> -sourceVHD <path to VHDX file>
  -skuName PremiumV2_LRS [-osType Windows|Linux] [-hyperVGeneration V1|V2]
  [-vmSize <VM size>] [-azcopyPath <path to azcopy>]

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -vmName <disk name prefix> -sourceVHD <path to VHD/VHDX>
  -diskType Data -attachToVM <existing VM name> [-skuName <disk SKU>]

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -configFile './upload_config.psd1'
  -vmName <VM Name> -sourceVHD <path to VHD file>

#>

[CmdletBinding()]
param (
  # Path to PSD1 config file for Azure environment variables
  [Parameter(Mandatory=$false)]
  [string]$configFile = '',
  # Azure VM Name - VM resource names will be derived from this
  [Parameter(Mandatory=$false)]
  [string]$vmName = '',
  # Source VHD or VHDX file to upload
  [Parameter(Mandatory=$false)]
  [string]$sourceVHD = '',
  # Disk type: OS (create new VM) or Data (attach to existing VM)
  [Parameter(Mandatory=$false)]
  [string]$diskType = '',
  # Existing VM name to attach data disk to (required for -diskType Data)
  [Parameter(Mandatory=$false)]
  [string]$attachToVM = '',
  # OS type: Windows or Linux (OS disks only)
  [Parameter(Mandatory=$false)]
  [string]$osType = '',
  # Hyper-V generation: V1 for MBR, V2 for GPT
  [Parameter(Mandatory=$false)]
  [string]$hyperVGeneration = '',
  # Azure VM size
  [Parameter(Mandatory=$false)]
  [string]$vmSize = '',
  # Managed disk SKU type
  [Parameter(Mandatory=$false)]
  [string]$skuName = '',
  # Path to AzCopy executable (required for VHDX uploads or -alwaysUseAzCopy)
  [Parameter(Mandatory=$false)]
  [string]$azcopyPath = '',
  # Use the direct upload (AzCopy) path even for VHD files instead of page blob upload
  [Parameter(Mandatory=$false)]
  [switch]$alwaysUseAzCopy = $false
)

### VARIABLES - BEGIN ###

if ($configFile -ne '') {
  if (-not (Test-Path $configFile)) {
    Write-Host "ERROR: Config file not found: $configFile" -foregroundcolor red
    exit 1
  }
  Write-Host "Loading config from: $configFile" -foregroundcolor green
  $configData = Import-PowerShellDataFile -Path $configFile
  # Load config values, but command-line params take precedence
  foreach ($key in $configData.Keys) {
    if (-not $PSBoundParameters.ContainsKey($key)) {
      Set-Variable -Name $key -Value $configData[$key]
    }
  }
}

### VARIABLES - END ###

## Validation
$validationErrors = @()

# Always required
if ([string]::IsNullOrEmpty($vmName)) { $validationErrors += "vmName is required" }
if ([string]::IsNullOrEmpty($sourceVHD)) { $validationErrors += "sourceVHD is required" }
if ([string]::IsNullOrEmpty($subscription)) { $validationErrors += "subscription is required" }
if ([string]::IsNullOrEmpty($resourceGroup)) { $validationErrors += "resourceGroup is required" }
if ([string]::IsNullOrEmpty($location)) { $validationErrors += "location is required" }
if ([string]::IsNullOrEmpty($diskType)) { $validationErrors += "diskType is required" }
if ([string]::IsNullOrEmpty($skuName)) { $validationErrors += "skuName is required" }

if ($validationErrors.Count -gt 0) {
  Write-Host "ERROR: Missing required values (set via -configFile or command-line parameters):" -foregroundcolor red
  $validationErrors | ForEach-Object { Write-Host "  - $_" -foregroundcolor red }
  exit 1
}

# Validate sourceVHD file exists
if (-not (Test-Path $sourceVHD)) {
  Write-Host "ERROR: Source file not found: $sourceVHD" -foregroundcolor red
  exit 1
}

# Detect VHD vs VHDX based on file extension
$isVHDX = $sourceVHD -match '\.vhdx$'
$useDirectUpload = $isVHDX -or $alwaysUseAzCopy

# VHDX requires GPT partitioning which is Azure Gen 2
if ($isVHDX -and $diskType -eq 'OS' -and $hyperVGeneration -ne 'V2') {
  Write-Host "VHDX detected - overriding hyperVGeneration to 'V2' (VHDX requires GPT/Gen 2)" -foregroundcolor yellow
  $hyperVGeneration = 'V2'
}

# Conditional validation based on disk type and upload method
$conditionalErrors = @()

if ($diskType -eq 'OS') {
  if ([string]::IsNullOrEmpty($osType)) { $conditionalErrors += "osType is required for OS disks" }
  if ([string]::IsNullOrEmpty($hyperVGeneration)) { $conditionalErrors += "hyperVGeneration is required for OS disks" }
  if ([string]::IsNullOrEmpty($vmSize)) { $conditionalErrors += "vmSize is required for OS disks" }
  if ([string]::IsNullOrEmpty($vnetRG)) { $conditionalErrors += "vnetRG is required for OS disks" }
  if ([string]::IsNullOrEmpty($vnetName)) { $conditionalErrors += "vnetName is required for OS disks" }
  if ([string]::IsNullOrEmpty($subnetName)) { $conditionalErrors += "subnetName is required for OS disks" }
  if ([string]::IsNullOrEmpty($nsgName)) { $conditionalErrors += "nsgName is required for OS disks" }
} elseif ($diskType -eq 'Data') {
  if ([string]::IsNullOrEmpty($attachToVM)) { $conditionalErrors += "attachToVM is required for data disks" }
} else {
  $conditionalErrors += "diskType must be 'OS' or 'Data' (got: '$diskType')"
}

if ($useDirectUpload) {
  if ([string]::IsNullOrEmpty($azcopyPath)) { $conditionalErrors += "azcopyPath is required for direct upload (VHDX or -alwaysUseAzCopy)" }
} else {
  if ([string]::IsNullOrEmpty($storageAccountName)) { $conditionalErrors += "storageAccountName is required for VHD page blob upload" }
  if ([string]::IsNullOrEmpty($storageContainerName)) { $conditionalErrors += "storageContainerName is required for VHD page blob upload" }
}

if ($conditionalErrors.Count -gt 0) {
  Write-Host "ERROR: Missing required values (set via -configFile or command-line parameters):" -foregroundcolor red
  $conditionalErrors | ForEach-Object { Write-Host "  - $_" -foregroundcolor red }
  exit 1
}

# VHDX SKU validation
if ($isVHDX) {
  if ($skuName -notin @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    Write-Host "ERROR: VHDX uploads are only supported on PremiumV2_LRS or UltraSSD_LRS SKUs." -foregroundcolor red
    Write-Host "Current SKU: $skuName" -foregroundcolor red
    Write-Host "Use -skuName PremiumV2_LRS or -skuName UltraSSD_LRS" -foregroundcolor red
    exit 1
  }
  Write-Host "Detected VHDX file - will use direct upload method" -foregroundcolor green
  Write-Host "  SKU: $skuName, LogicalSectorSize: 4096" -foregroundcolor green
} elseif ($alwaysUseAzCopy) {
  Write-Host "Detected VHD file - will use direct upload method (-alwaysUseAzCopy)" -foregroundcolor green
} else {
  Write-Host "Detected VHD file - will use page blob upload method" -foregroundcolor green
}

## Derived Variables
# Disk name uses vmName as prefix - change the suffix if uploading multiple disks
$diskName = $vmName + "-disk-01"
if ($diskType -eq 'OS') {
  $nicName = $vmName + "-nic-01"
}

# Login to Azure PowerShell
Write-Host "Logging in to Azure subscription: $subscription" -foregroundcolor green
Connect-AzAccount -subscription $subscription
Get-AzContext

if ($useDirectUpload) {
  ### Direct Upload Path (VHDX always, VHD when -alwaysUseAzCopy)
  $vhdSizeBytes = (Get-Item $sourceVHD).Length
  Write-Host "File size: $([math]::Round($vhdSizeBytes / 1GB, 2)) GB" -foregroundcolor green

  # Create an empty managed disk configured for direct upload
  Write-Host "Creating managed disk for upload: $diskName (SKU: $skuName, Type: $diskType)" -foregroundcolor green
  $diskConfigParams = @{
    SkuName           = $skuName
    Location          = $location
    CreateOption      = 'Upload'
    UploadSizeInBytes = $vhdSizeBytes
  }
  if ($isVHDX) {
    $diskConfigParams['LogicalSectorSize'] = 4096
  }
  if ($diskType -eq 'OS') {
    $diskConfigParams['HyperVGeneration'] = $hyperVGeneration
    $diskConfigParams['OsType'] = $osType
  }
  $diskConfig = New-AzDiskConfig @diskConfigParams

  $managedDisk = New-AzDisk `
      -ResourceGroupName $resourceGroup `
      -DiskName $diskName `
      -Disk $diskConfig

  # Generate a writable SAS URI (valid for 24 hours)
  Write-Host "Generating writable SAS for disk upload" -foregroundcolor green
  $diskSas = Grant-AzDiskAccess `
      -ResourceGroupName $resourceGroup `
      -DiskName $diskName `
      -DurationInSecond 86400 `
      -Access 'Write'

  # Upload using AzCopy
  Write-Host "Uploading via AzCopy: $sourceVHD" -foregroundcolor green
  & $azcopyPath copy $sourceVHD $diskSas.AccessSAS --blob-type PageBlob

  if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: AzCopy upload failed with exit code $LASTEXITCODE" -foregroundcolor red
    Write-Host "Revoking SAS access on failed upload" -foregroundcolor yellow
    Revoke-AzDiskAccess -ResourceGroupName $resourceGroup -DiskName $diskName
    exit 1
  }

  # Revoke the SAS to finalize the disk
  Write-Host "Upload complete - revoking SAS access to finalize disk" -foregroundcolor green
  Revoke-AzDiskAccess -ResourceGroupName $resourceGroup -DiskName $diskName

} else {
  ### VHD Page Blob Upload Path
  $storageBlobName = Split-Path -Path $sourceVHD -Leaf
  Write-Host "Uploading VHD to storage account: $storageAccountName/$storageContainerName/$storageBlobName" -foregroundcolor green

  # Get Storage Account context where the VHD will be uploaded to
  $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName
  $ctx = $storageAccount.Context

  # Upload the VHD as a page blob (mandatory blob type for images & disks)
  Set-AzStorageBlobContent `
      -File $sourceVHD `
      -Container $storageContainerName `
      -Blob $storageBlobName `
      -Context $ctx `
      -BlobType Page

  ### Create a Managed Disk from the uploaded VHD
  $vhdUri = "https://$storageAccountName.blob.core.windows.net/$storageContainerName/$storageBlobName"

  Write-Host "Creating managed disk: $diskName (SKU: $skuName, Type: $diskType)" -foregroundcolor green
  $diskConfigParams = @{
    SkuName          = $skuName
    Location         = $location
    CreateOption     = 'Import'
    SourceUri        = $vhdUri
    StorageAccountId = $storageAccount.Id
  }
  if ($diskType -eq 'OS') {
    $diskConfigParams['HyperVGeneration'] = $hyperVGeneration
    $diskConfigParams['OsType'] = $osType
  }
  $diskConfig = New-AzDiskConfig @diskConfigParams

  $managedDisk = New-AzDisk `
      -ResourceGroupName $resourceGroup `
      -DiskName $diskName `
      -Disk $diskConfig
}

# Check on the created Managed Disk
$disk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName
$disk | Select-Object Name, @{n='SkuName';e={$_.Sku.Name}}, DiskSizeGB, ProvisioningState, DiskState, OsType, Location

if ($diskType -eq 'OS') {
  ### Create a new VM from the Managed Disk (OS disk path)
  Write-Host "Creating VM: $vmName (Size: $vmSize)" -foregroundcolor green

  # Get the VNET, Subnet, and NSG details of where to create the VM NIC
  $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
  $subnet = $vnet | Select-Object -ExpandProperty Subnets | Where-Object Name -eq $subnetName
  $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroup -Name $nsgName

  # Create a new NIC
  $nic = New-AzNetworkInterface -Name $nicName `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -SubnetId $subnet.Id `
    -NetworkSecurityGroupId $nsg.Id `
    -EnableAcceleratedNetworking

  # Create a VM Config and attach the Managed Disk and NIC to it
  $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize
  if ($osType -eq 'Windows') {
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig `
      -ManagedDiskId $disk.Id `
      -Windows `
      -CreateOption Attach
  } else {
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig `
      -ManagedDiskId $disk.Id `
      -Linux `
      -CreateOption Attach
  }
  $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig `
    -Id $nic.Id

  # Create the VM using the VM Config as a background job
  $vmJob = New-AzVM -ResourceGroupName $resourceGroup `
    -Location $location `
    -VM $vmConfig `
    -Verbose `
    -AsJob

  # Check on the Job Status
  Get-Job -Id $vmJob.id | Select *

} else {
  ### Attach as a data disk to an existing VM (data disk path)
  Write-Host "Attaching data disk: $diskName to VM: $attachToVM" -foregroundcolor green

  $vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $attachToVM

  # Auto-assign the next available LUN
  $existingLuns = $vm.StorageProfile.DataDisks | ForEach-Object { $_.Lun }
  if ($existingLuns) {
    $nextLun = ($existingLuns | Measure-Object -Maximum).Maximum + 1
  } else {
    $nextLun = 0
  }

  $vm = Add-AzVMDataDisk -VM $vm `
    -ManagedDiskId $disk.Id `
    -Lun $nextLun `
    -CreateOption Attach

  Write-Host "Updating VM with new data disk at LUN $nextLun" -foregroundcolor green
  Update-AzVM -ResourceGroupName $resourceGroup -VM $vm
}
