# CSV Reference

Two CSVs drive the entire workflow. This is the complete column reference for
both.

---

# CSV 1: `rubrik_vm_list-<timestamp>.csv`

Produced by `Get-RubrikVMDKList.ps1`. **One row per VMDK**, so a VM with four
virtual disks produces four rows. Consumed by Phase 1 (conversion) and Phase 3
(FLR and SQL).

Legend:

- **Auto** - populated by `Get-RubrikVMDKList.ps1`. Do not edit.
- **User** - you fill this in. Merged forward on CSV regeneration.
- **Scope: VM** - the value is read once per VM, from the `BootDisk` row.
- **Scope: Disk** - the value applies to that one VMDK row.

## Disk action columns

These decide what happens to each VMDK.

| Column | Src | Scope | Required | Description |
|---|---|---|---|---|
| `Convert` | User | Disk | One of Convert/CreateOnly | Mark `x` or `y` to download, convert and upload this VMDK to Azure. |
| `CreateOnly` | User | Disk | One of Convert/CreateOnly | Mark `x` or `y` to create an **empty** Azure managed disk of the same size instead of transferring data. Attached to the VM as a raw disk for Phase 2 to initialize. |
| `BootDisk` | User | Disk | Yes, exactly one per VM | Mark `x` or `y` on the VM's OS disk. Determines the OS disk and the Hyper-V generation. Also the row the per-VM Azure settings are read from. |
| `DriveLetter` | User | Disk | No | Planning note only. **Not consumed by any script.** Use it to record which drive letter this VMDK held so you can cross-check against the Phase 2 drive info CSV. |

**Validation rules enforced by `Start-VMConversion.ps1`:**

- A row cannot have both `Convert` and `CreateOnly` marked. Hard error.
- A `CreateOnly` row cannot be a `BootDisk`. An empty disk cannot boot. Hard error.
- If no row has `Convert` or `CreateOnly`, the script exits with nothing to do.

**Why `CreateOnly` exists:** for data volumes where you want the disk present and
correctly sized in Azure but intend to repopulate the contents via Phase 3
(FLR or SQL restore) rather than transferring the full VMDK. Saves download,
conversion and upload time on large data volumes.

## Azure naming columns

| Column | Src | Scope | Required | Description |
|---|---|---|---|---|
| `tgtVMName` | User | VM | No | Target Azure VM name. Read from the `BootDisk` row only. Defaults to the source VMware VM name. Also used as the prefix for managed disk names and the NIC name. |
| `DiskSuffix` | User | Disk | No | Suffix for this disk's managed disk name. Final name is `{tgtVMName}-{DiskSuffix}`. Defaults to the VMDK leaf filename without extension. |

If the target VM name already exists in the resource group, the orchestrator
prefixes it with `az-` and continues. The NIC is always named
`{tgtVMName}-nic-01`.

## Azure placement columns

All read from the `BootDisk` row. Required when the upload stage runs.

| Column | Src | Required | Description |
|---|---|---|---|
| `ResourceGroup` | User | **Yes** | Resource group for the VM, NIC and all managed disks. |
| `VNetRG` | User | **Yes** | Resource group containing the virtual network. |
| `VNetName` | User | **Yes** | Virtual network name. |
| `SubnetName` | User | **Yes** | Subnet name within the VNet. |
| `VMSize` | User | **Yes** | Azure VM size SKU, e.g. `Standard_E2_v5`. |
| `NsgRG` | User | No | Resource group of the NSG. Defaults to `ResourceGroup` when blank. |
| `NsgName` | User | No | Network security group name. If blank, the NIC is created **without** an NSG and the script warns. |
| `ManagedDiskSku` | User | No | Per-VM override for disk SKU. Falls back to `skuName` in `conversion_config.psd1`. Valid: `Standard_LRS`, `StandardSSD_LRS`, `StandardSSD_ZRS`, `Premium_LRS`, `Premium_ZRS`. |

Missing any of the five required columns is a hard error before any work starts,
listed per VM.

## Phase 3 - FLR columns

A row enters the FLR job list only when **both** `sourceHostname` and
`sourceFlrDrive` are non-empty.

| Column | Src | Required | Description |
|---|---|---|---|
| `sourceHostname` | User | **Yes** | Name of the source Windows host in Rubrik that holds the volume group backup. Must match the host name registered in RSC. |
| `sourceFlrDrive` | User | **Yes** | Source drive letter(s) to restore. Comma separated for multiple, e.g. `G,H`. Trailing colons are stripped, so `G:` and `G` both work. |
| `targetRbsWinHost` | User | No | Target Windows host (with Rubrik Backup Service installed) to restore into. **Defaults to `tgtVMName` when blank.** |
| `targetFlrDrive` | User | No | Target drive letter(s), positionally mapped to `sourceFlrDrive`. If set, the count must match `sourceFlrDrive` or the script errors. If blank, restores to the same drive letter as the source. |

Jobs are deduplicated on the key `sourceHostname|targetHost`, and drive mappings
are merged across all rows sharing that key. So you can spread a multi-drive
restore across several VMDK rows and it still produces one job.

## Phase 3 - SQL columns

A row enters the SQL job list when `srcSqlInstance` is non-empty.

| Column | Src | Required | Description |
|---|---|---|---|
| `srcSqlInstance` | User | **Yes** | Source MSSQL instance name to export databases from. |
| `sqlDataPath` | User | **Yes** | Target path for restored data files, e.g. `E:\SQLData`. **A row with a blank data or log path is skipped with a warning, not an error.** |
| `sqlLogPath` | User | **Yes** | Target path for restored log files, e.g. `F:\SQLLogs`. Same skip behavior. |
| `tgtSqlInstance` | User | No | Target MSSQL instance. Defaults to `srcSqlInstance` when blank. |
| `targetRbsWinHost` | User | No | Target Windows host. Defaults to `tgtVMName` when blank. Shared with the FLR path. |

Jobs are deduplicated on `sourceHostname|targetHost`. The **first** matching row
wins; later rows with the same key are ignored. Keep SQL settings on one row per
server pair.

## Auto-populated columns

Do not edit these. They are refreshed from RSC on every run.

| Column | Description |
|---|---|
| `Name` | Source VMware VM name. |
| `SourceType` | `Primary` or `Replica`. Informational, lets you pick which cluster to recover from. |
| `Excluded` | `Y` if the VMDK is excluded from snapshots in Rubrik. Informational. A `Y` here means there is no backup data for this disk. |
| `vmdkSizeGiB` | Provisioned size in GiB. Used for disk space estimates and for sizing `CreateOnly` disks. |
| `vmdkSizeGB` | Provisioned size in GB (decimal). Informational. |
| `vmdkFile` | Full VMware path, e.g. `[datastore] vmname/vmname_1.vmdk`. Half of the merge key. |
| `Cluster` | Rubrik cluster holding the snapshot. Half of the merge key. |
| `SLA` | Effective SLA domain name. |
| `ID` | RSC VM object FID. Used to group rows into VMs and to trigger the download. |
| `LatestBackupID` / `LatestBackupDate` | Most recent snapshot. **This is the recovery point the conversion uses.** |
| `OldestBackupID` / `OldestBackupDate` | Oldest available snapshot. Informational. |
| `Notes` | Free text. Only read by the legacy `Main-Conversion-Script.ps1`. Ignored by `Start-VMConversion.ps1`. |

> **Recovery point selection:** the pipeline always uses `LatestBackupID`. To
> recover from an earlier point, edit `LatestBackupID` to the snapshot you want
> before running the conversion. Note that a later regeneration of the CSV will
> overwrite it, since it is an auto column.

## Merge behavior on regeneration

Re-running `Get-RubrikVMDKList.ps1` looks for the newest existing CSV matching
`csvOutputPrefix` and carries your edits forward, matched on
`vmdkFile` + `Cluster`.

Merged forward: `Convert`, `CreateOnly`, `DriveLetter`, `BootDisk`, `tgtVMName`,
`DiskSuffix`, `ResourceGroup`, `VNetRG`, `VNetName`, `SubnetName`, `NsgRG`,
`NsgName`, `VMSize`, `ManagedDiskSku`, `sourceHostname`, `targetRbsWinHost`,
`sourceFlrDrive`, `targetFlrDrive`, `srcSqlInstance`, `tgtSqlInstance`,
`sqlDataPath`, `sqlLogPath`.

Not merged: `Notes` is always reset to empty. All auto columns are refreshed.

Pass `-SkipMerge` to generate a clean CSV with no carried-forward edits.

---

# CSV 2: `drive_info-<COMPUTERNAME>.csv`

Produced by `Get-DriveInfo.ps1` on the **source** VM before migration. **One row
per volume that has a drive letter.** Consumed only by `Initialize-VMDrives.ps1`
inside the target Azure VM.

Every column is auto-captured. You normally do not edit this file.

| Column | Description |
|---|---|
| `ServerName` | Source computer name. Used by `-ServerName` to filter when one CSV holds multiple servers. |
| `Drive` | Drive letter, e.g. `E`. This is the letter that gets reassigned on the target. |
| `DriveType` | The **volume label** (from `FileSystemLabel`), despite the column name. Reapplied as the label on the target. |
| `TotalCapacityMB` | Volume size in MB. Primary field used to match a raw Azure disk to this row. |
| `UsedSpaceMB` | Used space in MB. Informational, useful for sizing decisions. |
| `TotalCapacityBytes` | Exact volume size in bytes. |
| `FileSystem` | e.g. `NTFS`, `ReFS`. Reapplied when formatting. |
| `AllocationUnitSizeKB` | Cluster size in KB. Reapplied when formatting. Matters for SQL volumes, which are commonly 64K. |
| `PartitionStyle` | `MBR` or `GPT`. Reapplied when initializing the disk. |
| `DiskNumber` | Source physical disk number. Used to group multiple volumes that shared one disk. |
| `DiskType` | `Basic` or `Dynamic`. **Dynamic disks are skipped and require manual work.** |
| `PartitionsOnDisk` | Count of lettered volumes on that source disk. Greater than 1 means a multi-partition disk. |
| `BusType` | Source bus type, e.g. `SCSI`. Informational. |
| `ScsiTarget` | SCSI target or LUN parsed from the disk location. Informational. |
| `DiskSizeGB` | Physical disk size in GB, which differs from volume size on multi-partition disks. |
| `IsSystem` | `Y` if the partition is the system or boot partition. |
| `IsBoot` | `Y` if the volume letter matches `%SystemDrive%`. |

## Warnings `Get-DriveInfo.ps1` raises

Read these before you migrate. They flag configurations the automation cannot
fully reproduce.

| Warning | Meaning | Action |
|---|---|---|
| Dynamic disk detected | Volume sits on a Logical Disk Manager dynamic disk | Not reproduced by `Initialize-VMDrives.ps1`. Plan manual configuration in Azure. |
| Multi-partition disk detected | Several lettered volumes share one physical disk | Handled, but verify the resulting partition sizes on the target. |
| Mount point volume detected | A volume mounted to a folder path with no drive letter | **Not written to the CSV at all.** Requires manual setup after migration. |
