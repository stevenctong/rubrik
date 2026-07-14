# PSD1 config file for Rubrik-New-v2-Ultra-Snapshot.ps1

@{
    ### Proxy VM Commands & Disk Names ###

    # If irisName is provided, mount points, VGs, LVs, freeze/thaw commands,
    # log path, and email subject are all derived from it.
    # Otherwise, define them explicitly below via MOUNTS, VGS, LVS, EPIC_FREEZE, EPIC_THAW.
    irisName = ''

    # Mount point sub-paths appended to MOUNT_BASE (used when irisName is empty)
    # e.g. MOUNT_BASE + '/ply01' = '/epic/ply01'
    MOUNTS = @('/ply01', '/relbld01')

    # Volume group names (used when irisName is empty)
    VGS = @('plyvg', 'relbldvg')

    # Logical volume names (used when irisName is empty)
    LVS = @('lv_ply', 'lv_relbld')

    # Azure Managed Disk names to snapshot (must match exact disk resource names)
    sourceDisks = @('iris-data-lun01', 'iris-data-lun02')

    # Base directory where all mount points live under
    MOUNT_BASE = '/epic'

    ### General ###

    # Number of days to keep snapshots
    snapDaysToKeep = 7
    # Number of days to keep cloned Managed Disks
    clonedDisksDaysToKeep = 7

    ### Azure ###

    # Source Disks - Subscription & Resource Group of the source disks
    sourceSubscriptionId = 'abcdefg-7820-42f8-b1cb-12345678'
    sourceResourceGroup = 'rg-source'

    # Target Proxy VM - Subscription & Resource Group where the Proxy VM is
    targetSubscriptionId = 'abcdefg-7820-42f8-b1cb-12345678'
    targetResourceGroup = 'rg-target'

    # Azure VM resource name of the Proxy VM
    proxyVM = 'iris-proxy-vm'

    # Snapshots will be named: <disk>-<sourceSnapshotSuffix>-<dateString>
    sourceSnapshotSuffix = 'rubrik-snap'

    # Cloned disks will be named: <disk>-<targetDiskSuffix>-<dateString>
    targetDiskSuffix = 'rubrik-disk'

    ### IRIS ODB ###

    # SSH freeze / thaw commands (used when irisName is empty)
    EPIC_FREEZE = 'sudo /epic/bin/instfreeze'
    EPIC_THAW = 'sudo /epic/bin/instthaw'

    # IRIS ODB Prod server hostname and SSH user
    EPIC_PRD_SERVER = 'AZIRISODB01'
    EPIC_PRD_USER = 'rbrkbkp'

    ### Execution Flags ###
    # Set to $false to skip individual steps (useful for debugging)

    executeEpicCommands = $true
    executeConnectToAzure = $true
    executeAzureCleanup = $true
    executeAzureSnapshot = $true
    executeManagedDiskClone = $true
    executeProxyDiskUnmountCommands = $true
    executeAzureDiskDetach = $true
    executeAzureDiskAttach = $true
    executeProxyMountCommands = $true

    ### Email ###
    # Sends script log output as an HTML email on completion

    # Set to $true to enable email notification
    sendMail = $false
    # Recipient email addresses
    emailTo = @()
    # Sender email address
    emailFrom = ''
    # SMTP server hostname
    SMTPServer = ''
    # Email subject line prefix (irisName and date are appended automatically)
    emailSubject = 'Rubrik Azure Script'

    ### Disk Performance ###
    # Performance config for v2 / Ultra cloned Managed Disks.
    # Acceptable values depend on the size of the Managed Disk.
    # Script has error handling if out of bounds to set to the max discovered value.

    DiskMBpsReadWrite = 800
    DiskMBpsReadOnly = 800
    DiskIOPSReadWrite = 10000
    DiskIOPSReadOnly = 10000

    ### Status Check ###

    # Seconds between polling checks for snapshot and disk copy background completion
    statusCheckSecs = 120

    ### Logging ###

    # Directory for log files (created if it does not exist)
    logDir = './logs'
    # Log filename prefix (irisName and date are appended automatically)
    logFilename = 'rubrik_azure_snap_script'
}
