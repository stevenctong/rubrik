# Prerequisites and Setup

## The staging host (Phase 1)

Phase 1 runs on a Windows host that downloads VMDKs, converts them, and uploads
to Azure. This host needs network reach to both the Rubrik cluster and Azure.

### Hyper-V role is mandatory, not just the tools

`Convert-VMDK-to-VHD.ps1` calls `Resize-VHD` to 1 MB align the output. Those
cmdlets go through the Hyper-V WMI provider, so the **full role** is required.
Management tools alone will not work.

```powershell
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
```

If the staging host is itself an Azure VM, you need nested virtualization:

- A Dv5/Dsv5 or newer SKU, e.g. `Standard_D8s_v5`
- Windows Server 2022 Datacenter or newer
- Alternatively deploy the "Hyper-V Server 2025" marketplace image from Cloud
  Infrastructure Services, which ships with the role installed

### Software

| Tool | Purpose | Source |
|---|---|---|
| PowerShell 7+ | All scripts. `ForEach-Object -Parallel` in the orchestrator requires it. | [install docs](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) |
| aria2c | Multi-connection VMDK download | [aria2.github.io](https://aria2.github.io/) |
| qemu-img | VMDK to fixed VHD conversion | [qemu.org/download](https://www.qemu.org/download/) |
| AzCopy v10 | Direct upload to managed disk | [AzCopy docs](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10) |
| Az PowerShell modules | `Az.Accounts`, `Az.Compute`, `Az.Network`. `Az.Storage` only if `useStorageAccount = $true`. | `Install-Module -Name Az -Scope CurrentUser` |

### Storage sizing

Budget roughly **2x the total provisioned size** of everything you convert in
one batch. Each VM needs its VMDK download plus its fixed VHD on disk at the
same time. `Start-VMConversion.ps1` prints a disk space summary before starting
and warns if the estimate exceeds free space, but it does not block.

Fixed VHD means fully allocated. A 500 GiB VMDK that is 40 GiB used still
produces a 500 GiB VHD.

Working directory layout the orchestrator creates:

```
<workingDir>\
  conversion_state.csv
  logs\
    conversion_master-<timestamp>.log
    conversion_stats.csv
  <VMName>\
    conversion.log
    conversion_report.json
    download\      <- .vmdk and -flat.vmdk
    converted\     <- .vhd
```

## RSC service account

All Rubrik-facing scripts authenticate with an RSC service account JSON file
containing `client_id`, `client_secret`, and `access_token_uri`.

`Download-RubrikVMDK.ps1` additionally opens a **CDM session directly against
the cluster**. It derives the cluster IP from the download URL Rubrik returns,
then POSTs the same `client_id` / `client_secret` to
`https://<clusterIP>/api/v1/service_account/session`. So the service account
must be valid at the cluster level too, and the staging host needs direct
HTTPS access to the Rubrik cluster nodes, not just to RSC.

Certificate validation is disabled for these cluster calls
(`-SkipCertificateCheck` and a global `ServerCertificateValidationCallback`).

### Required permissions

- Read VMware VM inventory and snapshots
- Trigger and download VM file exports
- For Phase 3 FLR: read Windows host volume groups, browse snapshots, initiate
  volume group file restore
- For Phase 3 SQL: read MSSQL hosts and instances, initiate bulk database export

## Azure prerequisites

- A subscription, resource group, VNet and subnet already in place. The scripts
  create disks, NICs and VMs but **do not create networking**.
- An NSG is optional. If `NsgName` is blank, the NIC is created without one and
  the script warns.
- Accelerated networking is enabled on every NIC the orchestrator creates.
  Confirm your chosen `VMSize` supports it.
- The account used by `Connect-AzAccount` needs Contributor or equivalent on
  the target resource group.

Login is interactive. `Start-VMConversion.ps1` calls `Connect-AzAccount` once up
front and passes `-SkipAzureLogin` to the child upload script.

### Direct upload vs storage account

Default is direct-to-managed-disk: `New-AzDisk -CreateOption Upload`, then
`Grant-AzDiskAccess` for a write SAS, then AzCopy. No storage account needed.

If direct upload fails, set `useStorageAccount = $true` in
`conversion_config.psd1` and fill in `storageAccountName`,
`storageContainerName` and `storageAccountRG`. That path uploads to a page blob
first, then creates the disk with `-CreateOption Import`.

## Target Azure VM prerequisites (Phase 2 and 3)

- **Phase 2** runs inside the recovered VM. It needs an elevated PowerShell
  session. No Rubrik or Azure connectivity required.
- **Phase 3** needs Rubrik Backup Service (RBS) installed and registered on the
  target Windows host, and the host must be **registered on the same Rubrik
  cluster as the source**. Both `Start-FLR.ps1` and `Start-SQLRestore.ps1`
  constrain the target lookup to the source's cluster ID.
- For the SQL path, the target SQL instance must exist and be registered in
  Rubrik. The target data and log paths must exist and be writable.

## Known constraints

| Constraint | Detail |
|---|---|
| 2 TB disk limit | VHD format caps at 2 TiB. `Convert-VMDK-to-VHD.ps1` skips anything larger with a warning and produces no report entry for it. Plan an alternate path for those volumes. |
| Dynamic disks | Not reproduced by `Initialize-VMDrives.ps1`. Flagged by `Get-DriveInfo.ps1`, then skipped. Manual work required. |
| Mount point volumes | Volumes mounted to a folder with no drive letter are never written to the drive info CSV. Manual work required. |
| Same-cluster targets only | Phase 3 target hosts must be registered on the same Rubrik cluster as the source. |
| No per-database SQL selection | `Start-SQLRestore.ps1` exports **all** databases on the source instance. There is no database-level filter. |
| SQL overwrite disabled | `allowOverwrite = $false`. The export fails if databases already exist on the target instance. |
