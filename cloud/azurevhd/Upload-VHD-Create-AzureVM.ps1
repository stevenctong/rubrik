<#
.SYNOPSIS
This script uploads a VHD to Azure as a managed disk via AzCopy and optionally
creates a VM or attaches the disk.

.DESCRIPTION
This script uploads a VHD to Azure and creates a managed disk. Two upload methods
are available:

Default (direct upload): Uploads VHD directly to a managed disk using
New-AzDisk -CreateOption Upload, Grant-AzDiskAccess for a write SAS URL, and
AzCopy. Requires VHD virtual size to be MiB-aligned. Simpler setup, live
progress output, no storage account needed.

Storage account (-UseStorageAccount): Uploads VHD to a storage account page blob
via AzCopy, then creates a managed disk via New-AzDisk -CreateOption Import.
Requires a storage account. Use as a fallback if direct upload fails.

For OS disks (-diskType OS): creates a new VM with the uploaded disk as the boot disk.
Supports both Gen 1 (MBR) and Gen 2 (GPT) managed disks via -hyperVGeneration.

For data disks (-diskType Data): uploads and creates the managed disk, then attaches
it to an existing VM specified by -attachToVM.

Use -diskName to override the managed disk resource name. When omitted, the disk
name defaults to "{vmName}-{vhdBaseName}".

Use -SkipVMCreation to upload the VHD and create the managed disk only (returns the
managed disk ID via stdout). The caller can then handle VM creation separately.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/28/25
Updated: 8/3/26

References:
- Azure VHD upload: https://learn.microsoft.com/en-us/azure/virtual-machines/windows/disks-upload-vhd-to-managed-disk-powershell

Requirements:
- Azure VM agent on the source VM: for easier troubleshooting in Azure - https://github.com/Azure/WindowsVMAgent

Azure PowerShell Notes:
Get all Azure resource SKUs: $sku = Get-AzComputeResourceSku -location <region>

Some additional options for consideration:
- Size of VM
- Additional Managed Disk options - tier of disk, performance for v2 / Ultra, encryption

.PARAMETER vmName
Azure VM name. For OS disks, VM resource names (disk, NIC) are derived from this.
For data disks, used as the disk name prefix.

.PARAMETER diskName
Override the managed disk resource name. When provided, used directly instead of
the default "{vmName}-{vhdBaseName}" derivation. Used by the orchestrator to pass
user-chosen disk names from the CSV DiskSuffix column.

.PARAMETER sourceVHD
Path to the source VHD file to upload.

.PARAMETER diskType
Whether the disk is an OS boot disk or a data disk. Valid values: 'OS', 'Data'.
Defaults to 'OS'. Data disks require -attachToVM.

.PARAMETER attachToVM
Name of the existing Azure VM to attach a data disk to. Required when -diskType is 'Data'.
The VM must be in the same resource group specified by -resourceGroup.

.PARAMETER subscription
Azure subscription name or ID.

.PARAMETER resourceGroup
Azure resource group for the VM, NIC, and managed disk.

.PARAMETER location
Azure region (e.g., 'eastus2').

.PARAMETER azcopyPath
Path to the azcopy.exe executable for uploading VHDs to Azure page blobs.

.PARAMETER UseStorageAccount
Use the storage account page blob upload method instead of direct-to-managed-disk.
Requires -storageAccountName, -storageContainerName, and -storageAccountRG.

.PARAMETER storageAccountName
Azure storage account name for VHD page blob upload. Required with -UseStorageAccount.

.PARAMETER storageContainerName
Blob container name in the storage account (e.g., 'vhds'). Required with -UseStorageAccount.

.PARAMETER storageAccountRG
Resource group of the storage account. Required with -UseStorageAccount.

.PARAMETER SkipVMCreation
Upload the VHD and create the managed disk only. Skips VM creation (OS disks) or
disk attachment (data disks). Returns the managed disk resource ID via stdout so the
caller can handle VM creation separately. Used by the orchestrator to upload all
disks first, then create the VM with all disks in a single call.

.PARAMETER osType
OS type of the disk (OS disks only). Valid values: 'Windows', 'Linux'. Defaults to 'Windows'.

.PARAMETER hyperVGeneration
Hyper-V generation for the managed disk (OS disks only). Use 'V1' for MBR, 'V2' for GPT.
Defaults to 'V1'.

.PARAMETER vmSize
Azure VM size SKU (OS disks only). Defaults to 'Standard_E2_v5'.

.PARAMETER skuName
Managed disk SKU type. Defaults to 'StandardSSD_LRS'.
Options: Standard_LRS, Premium_LRS, Premium_ZRS, StandardSSD_LRS, StandardSSD_ZRS

.PARAMETER vnetRG
Resource group containing the target VNet (OS disks only).

.PARAMETER vnetName
Target VNet name (OS disks only).

.PARAMETER subnetName
Target subnet name within the VNet (OS disks only).

.PARAMETER nsgRG
Resource group containing the NSG. Defaults to the value of -resourceGroup
if not specified.

.PARAMETER nsgName
Network Security Group to attach to the NIC (OS disks only).

.PARAMETER SkipAzureLogin
Skip the Connect-AzAccount login prompt. Use when Azure authentication is
already established (e.g., when called from the Start-VMConversion.ps1
orchestrator). Fails if no existing Az context is found.

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -vmName <VM Name> -sourceVHD <path to VHD file>
  -azcopyPath <path to azcopy.exe>
  -subscription <sub> -resourceGroup <rg> -location <region>
  -vnetRG <vnet-rg> -vnetName <vnet> -subnetName <subnet> -nsgName <nsg>
  [-osType Windows|Linux] [-hyperVGeneration V1|V2]
  [-vmSize <VM size>] [-skuName <disk SKU>]
Direct upload (default) - uploads VHD directly to managed disk.

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -vmName <VM Name> -sourceVHD <path to VHD file>
  -azcopyPath <path to azcopy.exe> -UseStorageAccount
  -storageAccountName <storage account> -storageContainerName vhds -storageAccountRG <sa-rg>
  -subscription <sub> -resourceGroup <rg> -location <region>
  -vnetRG <vnet-rg> -vnetName <vnet> -subnetName <subnet> -nsgName <nsg>
  [-osType Windows|Linux] [-hyperVGeneration V1|V2]
  [-vmSize <VM size>] [-skuName <disk SKU>]
Storage account upload - uploads VHD to page blob, then creates managed disk via Import.

.EXAMPLE
$diskId = ./Upload-VHD-Create-AzureVM.ps1 -vmName <VM Name> -sourceVHD <path to VHD>
  -azcopyPath <path to azcopy.exe> -diskType OS -SkipVMCreation
  -subscription <sub> -resourceGroup <rg> -location <region>
  [-osType Windows|Linux] [-hyperVGeneration V1|V2] [-skuName <disk SKU>]
Direct upload with -SkipVMCreation - returns managed disk ID via stdout.

#>

[CmdletBinding()]
param (
  # Azure VM Name - VM resource names will be derived from this
  [Parameter(Mandatory=$false)]
  [string]$vmName = '',
  # Override managed disk resource name (default: "{vmName}-{vhdBaseName}")
  [Parameter(Mandatory=$false)]
  [string]$diskName = '',
  # Source VHD file to upload
  [Parameter(Mandatory=$false)]
  [string]$sourceVHD = '',
  # Disk type: OS (create new VM) or Data (attach to existing VM)
  [Parameter(Mandatory=$false)]
  [string]$diskType = '',
  # Existing VM name to attach data disk to (required for -diskType Data)
  [Parameter(Mandatory=$false)]
  [string]$attachToVM = '',
  # Azure subscription name or ID
  [Parameter(Mandatory=$false)]
  [string]$subscription = '',
  # Azure resource group for VM, NIC, and managed disk
  [Parameter(Mandatory=$false)]
  [string]$resourceGroup = '',
  # Azure region
  [Parameter(Mandatory=$false)]
  [string]$location = '',
  # Path to azcopy.exe
  [Parameter(Mandatory=$false)]
  [string]$azcopyPath = '',
  # Use storage account page blob upload instead of direct-to-managed-disk
  [Parameter(Mandatory=$false)]
  [switch]$UseStorageAccount = $false,
  # Azure storage account name for VHD page blob upload (required with -UseStorageAccount)
  [Parameter(Mandatory=$false)]
  [string]$storageAccountName = '',
  # Blob container name in the storage account
  [Parameter(Mandatory=$false)]
  [string]$storageContainerName = '',
  # Resource group of the storage account
  [Parameter(Mandatory=$false)]
  [string]$storageAccountRG = '',
  # Upload VHD and create managed disk only (skip VM creation / disk attachment)
  [Parameter(Mandatory=$false)]
  [switch]$SkipVMCreation = $false,
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
  # Resource group containing the target VNet (OS disks only)
  [Parameter(Mandatory=$false)]
  [string]$vnetRG = '',
  # Target VNet name (OS disks only)
  [Parameter(Mandatory=$false)]
  [string]$vnetName = '',
  # Target subnet name (OS disks only)
  [Parameter(Mandatory=$false)]
  [string]$subnetName = '',
  # Resource group containing the NSG
  [Parameter(Mandatory=$false)]
  [string]$nsgRG = '',
  # NSG to attach to the NIC (OS disks only)
  [Parameter(Mandatory=$false)]
  [string]$nsgName = '',
  # Skip Azure login (use existing Az context)
  [Parameter(Mandatory=$false)]
  [switch]$SkipAzureLogin = $false
)

### VARIABLES - BEGIN ###

# Default nsgRG to resourceGroup if not specified
if ([string]::IsNullOrEmpty($nsgRG)) {
  $nsgRG = $resourceGroup
}

### VARIABLES - END ###

# Log prefix for parallel execution visibility
$logPrefix = if ($vmName -ne '') { "[$vmName] " } else { '' }
$uploadStartTime = Get-Date
Write-Host "${logPrefix}Upload started: $($uploadStartTime.ToString('M/d/yy h:mm:ss tt'))" -ForegroundColor Cyan

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
if ([string]::IsNullOrEmpty($azcopyPath)) { $validationErrors += "azcopyPath is required" }
if ($UseStorageAccount) {
  if ([string]::IsNullOrEmpty($storageAccountName)) { $validationErrors += "storageAccountName is required with -UseStorageAccount" }
  if ([string]::IsNullOrEmpty($storageContainerName)) { $validationErrors += "storageContainerName is required with -UseStorageAccount" }
  if ([string]::IsNullOrEmpty($storageAccountRG)) { $validationErrors += "storageAccountRG is required with -UseStorageAccount" }
}

if ($validationErrors.Count -gt 0) {
  Write-Host "ERROR: Missing required values:" -foregroundcolor red
  $validationErrors | ForEach-Object { Write-Host "  - $_" -foregroundcolor red }
  exit 1
}

# Validate sourceVHD is a file (not a directory) and exists
if (-not (Test-Path $sourceVHD -PathType Leaf)) {
  if (Test-Path $sourceVHD -PathType Container) {
    Write-Host "${logPrefix}ERROR: sourceVHD is a directory, not a file: $sourceVHD" -foregroundcolor red
    Write-Host "${logPrefix}Provide a VHD file path, not a directory." -foregroundcolor yellow
  } else {
    Write-Host "${logPrefix}ERROR: Source file not found: $sourceVHD" -foregroundcolor red
  }
  exit 1
}

$uploadMethod = if ($UseStorageAccount) { "storage account page blob" } else { "direct-to-managed-disk" }
Write-Host "${logPrefix}Upload method: $uploadMethod" -foregroundcolor green

# Conditional validation based on disk type
$conditionalErrors = @()

if ($diskType -eq 'OS') {
  if ([string]::IsNullOrEmpty($osType)) { $conditionalErrors += "osType is required for OS disks" }
  if ([string]::IsNullOrEmpty($hyperVGeneration)) { $conditionalErrors += "hyperVGeneration is required for OS disks" }
  if (-not $SkipVMCreation) {
    if ([string]::IsNullOrEmpty($vmSize)) { $conditionalErrors += "vmSize is required for OS disks" }
    if ([string]::IsNullOrEmpty($vnetRG)) { $conditionalErrors += "vnetRG is required for OS disks" }
    if ([string]::IsNullOrEmpty($vnetName)) { $conditionalErrors += "vnetName is required for OS disks" }
    if ([string]::IsNullOrEmpty($subnetName)) { $conditionalErrors += "subnetName is required for OS disks" }
    if ([string]::IsNullOrEmpty($nsgName)) { $conditionalErrors += "nsgName is required for OS disks" }
  }
} elseif ($diskType -eq 'Data') {
  if (-not $SkipVMCreation -and [string]::IsNullOrEmpty($attachToVM)) { $conditionalErrors += "attachToVM is required for data disks" }
} else {
  $conditionalErrors += "diskType must be 'OS' or 'Data' (got: '$diskType')"
}

if ($conditionalErrors.Count -gt 0) {
  Write-Host "ERROR: Missing required values:" -foregroundcolor red
  $conditionalErrors | ForEach-Object { Write-Host "  - $_" -foregroundcolor red }
  exit 1
}

## Check prerequisite Azure PowerShell modules
$requiredModules = @('Az.Accounts', 'Az.Compute')
if ($UseStorageAccount) { $requiredModules += 'Az.Storage' }
if ($diskType -eq 'OS' -and -not $SkipVMCreation) { $requiredModules += 'Az.Network' }

$missingModules = @()
foreach ($mod in $requiredModules) {
  if (-not (Get-Module -ListAvailable -Name $mod)) {
    $missingModules += $mod
  }
}
if ($missingModules.Count -gt 0) {
  Write-Host "${logPrefix}ERROR: Missing required Azure PowerShell modules:" -foregroundcolor red
  $missingModules | ForEach-Object { Write-Host "${logPrefix}  - $_" -foregroundcolor red }
  Write-Host ""
  Write-Host "${logPrefix}Install all Az modules:  Install-Module -Name Az -Scope CurrentUser" -foregroundcolor yellow
  Write-Host "${logPrefix}Or install individually:  Install-Module -Name $($missingModules[0]) -Scope CurrentUser" -foregroundcolor yellow
  exit 1
}

# Check azcopy exists
if (-not (Test-Path $azcopyPath -PathType Leaf)) {
  Write-Host "${logPrefix}ERROR: azcopy not found at: $azcopyPath" -foregroundcolor red
  exit 1
}

## Derived Variables
$vhdBaseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceVHD)
if ([string]::IsNullOrEmpty($diskName)) {
  $diskName = "$vmName-$vhdBaseName"
}
if ($diskType -eq 'OS') {
  $nicName = $vmName + "-nic-01"
}

# Login to Azure PowerShell
if ($SkipAzureLogin) {
  $azContext = Get-AzContext -ErrorAction SilentlyContinue
  if ($null -eq $azContext) {
    Write-Host "${logPrefix}ERROR: -SkipAzureLogin specified but no existing Azure context found. Run Connect-AzAccount first." -foregroundcolor red
    exit 1
  }
  if ($azContext.Subscription.Name -ne $subscription -and $azContext.Subscription.Id -ne $subscription) {
    Write-Host "${logPrefix}Setting Azure subscription context to: $subscription" -foregroundcolor green
    Set-AzContext -Subscription $subscription -ErrorAction Stop | Out-Null
    $azContext = Get-AzContext
  }
} else {
  Write-Host "${logPrefix}Logging in to Azure subscription: $subscription" -foregroundcolor green
  try {
    Connect-AzAccount -Subscription $subscription -ErrorAction Stop | Out-Null
  } catch {
    Write-Host "${logPrefix}ERROR: Azure login failed: $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }
  $azContext = Get-AzContext -ErrorAction Stop
  if ($null -eq $azContext) {
    Write-Host "${logPrefix}ERROR: No Azure context found after login. Run Connect-AzAccount manually to troubleshoot." -foregroundcolor red
    exit 1
  }
}
Write-Host "${logPrefix}Logged in as: $($azContext.Account.Id) (Subscription: $($azContext.Subscription.Name))" -foregroundcolor green

### AzCopy Upload and Managed Disk Creation
$vhdFileSize = (Get-Item $sourceVHD).Length
$vhdSizeGiB = [math]::Round($vhdFileSize / 1073741824, 1)
$vhdFileName = Split-Path $sourceVHD -Leaf
Write-Host "${logPrefix}Uploading VHD via AzCopy: $vhdFileName ($vhdSizeGiB GiB)" -foregroundcolor green

if ($UseStorageAccount) {
  ### Storage Account Page Blob Upload -> Managed Disk Import

  # Get storage account and container
  Write-Host "${logPrefix}Getting storage account: $storageAccountName (RG: $storageAccountRG)" -foregroundcolor green
  try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to get storage account '$storageAccountName': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }
  $storageContext = $storageAccount.Context

  $container = Get-AzStorageContainer -Name $storageContainerName -Context $storageContext -ErrorAction SilentlyContinue
  if ($null -eq $container) {
    Write-Host "${logPrefix}Creating container '$storageContainerName'..." -foregroundcolor green
    try {
      $container = New-AzStorageContainer -Name $storageContainerName -Context $storageContext -ErrorAction Stop
    } catch {
      Write-Host "${logPrefix}ERROR: Failed to create container '$storageContainerName': $($_.Exception.Message)" -foregroundcolor red
      exit 1
    }
  }

  # Generate a SAS token for the container (24-hour expiry)
  $sasToken = New-AzStorageContainerSASToken -Name $storageContainerName -Context $storageContext `
    -Permission rwdl -ExpiryTime (Get-Date).AddHours(24)

  # Build the blob URL
  $blobUrl = "https://$storageAccountName.blob.core.windows.net/$storageContainerName/$vhdFileName"
  if (-not $sasToken.StartsWith('?')) { $sasToken = "?$sasToken" }
  $blobUrlWithSas = "$blobUrl$sasToken"

  # Upload VHD via AzCopy using Start-Process to avoid PowerShell glob-expanding
  # the '?' in the SAS URL (PowerShell treats '?' as a wildcard in native command args)
  Write-Host "${logPrefix}Starting AzCopy upload to page blob..." -foregroundcolor green
  Write-Host "${logPrefix}  Destination: $blobUrl" -foregroundcolor green
  $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) "azcopy_out_$([guid]::NewGuid().ToString('N')).log"
  $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "azcopy_err_$([guid]::NewGuid().ToString('N')).log"
  $proc = Start-Process -FilePath $azcopyPath `
    -ArgumentList "copy `"$sourceVHD`" `"$blobUrlWithSas`" --blob-type PageBlob" `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
  $azcopyExitCode = $proc.ExitCode
  $azcopyOutput = @()
  if (Test-Path $stdoutFile) { $azcopyOutput += Get-Content $stdoutFile }
  if (Test-Path $stderrFile) { $azcopyOutput += Get-Content $stderrFile }
  Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  $azcopyOutput | Where-Object {
    $line = $_.ToString().Trim()
    $line -ne '' -and $line -notmatch '^\d+\.\d+ %' -and $line -notmatch '^DONE'
  } | ForEach-Object { Write-Host "${logPrefix}  $_" }

  if ($azcopyExitCode -ne 0) {
    Write-Host "${logPrefix}ERROR: AzCopy upload failed (exit code: $azcopyExitCode)" -foregroundcolor red
    Write-Host "${logPrefix}Cleaning up blob..." -foregroundcolor yellow
    Remove-AzStorageBlob -Container $storageContainerName -Blob $vhdFileName -Context $storageContext -ErrorAction SilentlyContinue
    exit 1
  }

  # Create managed disk from the uploaded page blob
  Write-Host "${logPrefix}Creating managed disk from page blob: $diskName (SKU: $skuName)" -foregroundcolor green
  $diskConfigParams = @{
    SkuName      = $skuName
    Location     = $location
    CreateOption = 'Import'
    SourceUri    = $blobUrl
    StorageAccountId = $storageAccount.Id
  }
  if ($diskType -eq 'OS') {
    $diskConfigParams['HyperVGeneration'] = $hyperVGeneration
    $diskConfigParams['OsType'] = $osType
  }
  $diskConfig = New-AzDiskConfig @diskConfigParams

  try {
    $disk = New-AzDisk `
        -ResourceGroupName $resourceGroup `
        -DiskName $diskName `
        -Disk $diskConfig `
        -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to create managed disk '$diskName': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }

} else {
  ### Direct Upload to Managed Disk

  # Calculate upload size (VHD content size = file size minus 512-byte footer)
  $uploadSize = $vhdFileSize - 512
  Write-Host "${logPrefix}VHD content size for upload: $uploadSize bytes ($([math]::Round($uploadSize / 1GB, 2)) GiB)" -foregroundcolor green

  # Create an empty managed disk configured for upload
  Write-Host "${logPrefix}Creating managed disk for direct upload: $diskName (SKU: $skuName)" -foregroundcolor green
  $diskConfigParams = @{
    SkuName           = $skuName
    Location          = $location
    CreateOption      = 'Upload'
    UploadSizeInBytes = $vhdFileSize
  }
  if ($diskType -eq 'OS') {
    $diskConfigParams['HyperVGeneration'] = $hyperVGeneration
    $diskConfigParams['OsType'] = $osType
  }
  $diskConfig = New-AzDiskConfig @diskConfigParams

  try {
    $disk = New-AzDisk `
        -ResourceGroupName $resourceGroup `
        -DiskName $diskName `
        -Disk $diskConfig `
        -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to create managed disk '$diskName': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }

  # Grant write access to the managed disk (returns a SAS URL)
  Write-Host "${logPrefix}Granting write access to managed disk..." -foregroundcolor green
  try {
    $diskSas = Grant-AzDiskAccess `
        -ResourceGroupName $resourceGroup `
        -DiskName $diskName `
        -Access Write `
        -DurationInSecond 86400 `
        -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to grant disk access: $($_.Exception.Message)" -foregroundcolor red
    Write-Host "${logPrefix}Cleaning up managed disk..." -foregroundcolor yellow
    Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName -Force -ErrorAction SilentlyContinue
    exit 1
  }

  # Upload VHD via AzCopy to the managed disk SAS URL
  Write-Host "${logPrefix}Starting AzCopy upload to managed disk..." -foregroundcolor green
  $azcopyOutput = & $azcopyPath copy $sourceVHD $diskSas.AccessSAS --blob-type PageBlob 2>&1
  $azcopyExitCode = $LASTEXITCODE
  $azcopyOutput | Where-Object {
    $line = $_.ToString().Trim()
    $line -ne '' -and $line -notmatch '^\d+\.\d+ %' -and $line -notmatch '^DONE'
  } | ForEach-Object { Write-Host "${logPrefix}  $_" }

  if ($azcopyExitCode -ne 0) {
    Write-Host "${logPrefix}ERROR: AzCopy upload failed (exit code: $azcopyExitCode)" -foregroundcolor red
    Write-Host "${logPrefix}Revoking disk access and cleaning up..." -foregroundcolor yellow
    Revoke-AzDiskAccess -ResourceGroupName $resourceGroup -DiskName $diskName -ErrorAction SilentlyContinue
    Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName -Force -ErrorAction SilentlyContinue
    exit 1
  }

  # Revoke write access to finalize the disk
  Write-Host "${logPrefix}Revoking disk write access..." -foregroundcolor green
  $null = Revoke-AzDiskAccess -ResourceGroupName $resourceGroup -DiskName $diskName -ErrorAction Stop
}

# Verify the managed disk
try {
  $disk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName -ErrorAction Stop
} catch {
  Write-Host "${logPrefix}ERROR: Failed to retrieve managed disk '$diskName': $($_.Exception.Message)" -foregroundcolor red
  exit 1
}
$diskInfo = $disk | Select-Object Name, @{n='SkuName';e={$_.Sku.Name}}, DiskSizeGB, ProvisioningState, DiskState, OsType, Location
Write-Host "${logPrefix}Managed disk created:"
$diskInfo | Format-Table | Out-String | ForEach-Object { Write-Host "${logPrefix}  $_" }

if ($disk.ProvisioningState -ne 'Succeeded') {
  Write-Host "${logPrefix}ERROR: Managed disk '$diskName' is not healthy (ProvisioningState: $($disk.ProvisioningState), DiskState: $($disk.DiskState))" -foregroundcolor red
  Write-Host "${logPrefix}Delete the failed disk in Azure and retry." -foregroundcolor yellow
  exit 1
}

# If SkipVMCreation, return the disk ID and exit
if ($SkipVMCreation) {
  Write-Host "${logPrefix}SkipVMCreation set - returning managed disk ID" -foregroundcolor green
  $uploadEndTime = Get-Date
  $uploadElapsed = $uploadEndTime - $uploadStartTime
  Write-Host "${logPrefix}Upload completed: $($uploadEndTime.ToString('M/d/yy h:mm:ss tt')) (elapsed: $([math]::Round($uploadElapsed.TotalMinutes, 1)) min)" -ForegroundColor Cyan
  Write-Output $disk.Id
  exit 0
}

if ($diskType -eq 'OS') {
  ### Create a new VM from the Managed Disk (OS disk path)
  Write-Host "${logPrefix}Creating VM: $vmName (Size: $vmSize)" -foregroundcolor green

  # Get the VNET, Subnet, and NSG details of where to create the VM NIC
  try {
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to get VNET '$vnetName' in resource group '$vnetRG': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }
  $subnet = $vnet | Select-Object -ExpandProperty Subnets | Where-Object Name -eq $subnetName
  if ($null -eq $subnet) {
    Write-Host "${logPrefix}ERROR: Subnet '$subnetName' not found in VNET '$vnetName'" -foregroundcolor red
    exit 1
  }
  try {
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgRG -Name $nsgName -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to get NSG '$nsgName' in RG '$nsgRG': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }

  # Create a new NIC
  try {
    $nic = New-AzNetworkInterface -Name $nicName `
      -ResourceGroupName $resourceGroup `
      -Location $location `
      -SubnetId $subnet.Id `
      -NetworkSecurityGroupId $nsg.Id `
      -EnableAcceleratedNetworking `
      -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to create NIC '$nicName': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }

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

  # Create the VM
  try {
    Write-Host "${logPrefix}Creating Azure VM (this may take several minutes)..." -foregroundcolor green
    New-AzVM -ResourceGroupName $resourceGroup `
      -Location $location `
      -VM $vmConfig `
      -ErrorAction Stop | Out-Null
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to create VM '$vmName': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }
  Write-Host "${logPrefix}VM '$vmName' created successfully." -foregroundcolor green

} else {
  ### Attach as a data disk to an existing VM (data disk path)
  Write-Host "${logPrefix}Attaching data disk: $diskName to VM: $attachToVM" -foregroundcolor green

  try {
    $vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $attachToVM -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to get VM '$attachToVM': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }

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

  Write-Host "${logPrefix}Updating VM with new data disk at LUN $nextLun" -foregroundcolor green
  try {
    Update-AzVM -ResourceGroupName $resourceGroup -VM $vm -ErrorAction Stop
  } catch {
    Write-Host "${logPrefix}ERROR: Failed to attach data disk to VM '$attachToVM': $($_.Exception.Message)" -foregroundcolor red
    exit 1
  }
}

$uploadEndTime = Get-Date
$uploadElapsed = $uploadEndTime - $uploadStartTime
Write-Host "${logPrefix}Upload completed: $($uploadEndTime.ToString('M/d/yy h:mm:ss tt')) (elapsed: $([math]::Round($uploadElapsed.TotalMinutes, 1)) min)" -ForegroundColor Cyan
