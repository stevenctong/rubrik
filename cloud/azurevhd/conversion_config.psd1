@{
    # RSC Service Account JSON file path
    RscServiceAccountJson = './rsc-service-account-rr.json'

    # VMDK CSV from Get-RubrikVMDKList.ps1
    # vmCsvFile = './rubrik_vm_list-2026-08-02_1430.csv'

    # Base directory for downloads, conversions, and logs
    workingDir = 'F:\conversions'

    # Max parallel VMs
    throttleLimit = 5

    # Path to aria2c.exe
    aria2cPath = 'F:\aria2\aria2c.exe'

    # Path to qemu-img.exe
    qemuPath = 'C:\Program Files\qemu\qemu-img.exe'

    # Path to azcopy.exe
    azcopyPath = 'F:\azcopy\azcopy.exe'

    # Max minutes to wait for download preparation per VM
    timeoutMinutes = 60

    # Stage toggles (default: $true) - set to $false to skip a stage
    RunDownload = $true
    RunConvert  = $true
    RunUpload   = $true

    ### Azure Environment (shared across all VMs) ###

    # Azure subscription name or ID
    subscription = 'RR-PRD'

    # Azure region
    location = 'eastus2'

    # (Optional) Use storage account page blob upload instead of direct-to-managed-disk
    # Set to $true as a fallback if direct upload fails
    useStorageAccount = $false

    # (Optional) Azure storage account for VHD page blob upload (intermediary before managed disk)
    # Only required when useStorageAccount = $true
    storageAccountName = 'rrtonglighthouse101'

    # (Optional) Blob container name in the storage account
    storageContainerName = 'vhds'

    # (Optional) Resource group of the storage account
    storageAccountRG = 'rr-tong'

    # Default OS type (Windows or Linux)
    osType = 'Windows'

    # Default managed disk SKU (per-VM CSV column overrides this)
    # Options: Standard_LRS, Premium_LRS, Premium_ZRS, StandardSSD_LRS, StandardSSD_ZRS
    skuName = 'StandardSSD_LRS'
}
