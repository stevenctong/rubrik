# PSD1 config file for Upload-VHD-Create-AzureVM.ps1
# Copy this file, fill in your values, and pass via -configFile
# Command-line parameters override config file values when both are provided.

@{
    ### Azure Environment ###

    # Azure Subscription to login to
    subscription = 'RR-PRD'

    # Resource group and region
    resourceGroup = 'rr-tong-lighthouse'
    location = 'eastus2'

    ### Storage Account (VHD page blob upload path only) ###

    storageAccountName = 'rrtonglighthouse150'
    storageContainerName = 'vhds'

    ### Networking (OS disk VM creation only) ###

    vnetRG = 'rg-rr2-eastus2-networking'
    vnetName = 'vnet-rr2-eastus2'
    subnetName = 'main1'
    nsgName = 'rr-tong-nsg'

    ### VM and Disk Settings ###

    # Azure VM name - VM resource names (disk, NIC) are derived from this
    vmName = ''

    # Path to the source VHD or VHDX file to upload
    sourceVHD = ''

    # Disk type: 'OS' (create new VM) or 'Data' (attach to existing VM)
    diskType = 'OS'

    # Existing VM name to attach data disk to (required when diskType is 'Data')
    attachToVM = ''

    # OS type: 'Windows' or 'Linux' (OS disks only)
    osType = 'Windows'

    # Hyper-V generation: 'V1' for MBR, 'V2' for GPT (OS disks only)
    hyperVGeneration = 'V1'

    # Azure VM size SKU (OS disks only)
    vmSize = 'Standard_E2_v5'

    # Managed disk SKU type
    # Options: Standard_LRS, Premium_LRS, Premium_ZRS, StandardSSD_LRS,
    #          StandardSSD_ZRS, PremiumV2_LRS, UltraSSD_LRS
    # Note: VHDX uploads require PremiumV2_LRS or UltraSSD_LRS
    skuName = 'StandardSSD_LRS'

    # Path to AzCopy executable (required for VHDX uploads or alwaysUseAzCopy)
    # Download: https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
    azcopyPath = 'azcopy'

    # Use the direct upload (AzCopy) path even for VHD files
    alwaysUseAzCopy = $false
}
