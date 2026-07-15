# PSD1 config file for Upload-VHD-Create-AzureVM.ps1
# Copy this file, fill in your values, and pass via -configFile

@{
    # Azure Subscription to login to
    subscription = 'RR-PRD'

    # Resource group and region
    resourceGroup = 'rr-tong-lighthouse'
    location = 'eastus2'

    # Storage Account variables (VHD page blob upload path only)
    storageAccountName = 'rrtonglighthouse150'
    storageContainerName = 'vhds'

    # Networking details (OS disk VM creation only)
    vnetRG = 'rg-rr2-eastus2-networking'
    vnetName = 'vnet-rr2-eastus2'
    subnetName = 'main1'
    nsgName = 'rr-tong-nsg'
}
