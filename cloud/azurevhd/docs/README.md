# azurevhd Documentation

Source markdown for the VMware to Azure mass recovery runbook. The rendered
single-page version is `../rubrik_azure_vhd_recovery.html`.

## Files

| File | Contents |
|---|---|
| [00-overview.md](00-overview.md) | The three phases, the two CSVs, script inventory, end-to-end flow diagram |
| [01-phase1-conversion.md](01-phase1-conversion.md) | Conversion runbook: generate CSV, configure, run, stage internals, resume behavior |
| [02-phase2-drives.md](02-phase2-drives.md) | Drive capture and rebuild, disk matching rules, multi-partition handling |
| [03-phase3-flr-sql.md](03-phase3-flr-sql.md) | FLR and MSSQL export paths, state machines, status polling |
| [04-csv-reference.md](04-csv-reference.md) | Every column in both CSVs, required vs optional, merge behavior |
| [05-prereqs.md](05-prereqs.md) | Tooling, Hyper-V role, storage sizing, RSC and Azure setup, known constraints |

## Keeping this in step with the scripts

The docs describe behavior verified against the scripts as of **9/11/26**. When
you change a script, check whether it touches any of these:

- **CSV columns** added, removed or renamed in `Get-RubrikVMDKList.ps1` or
  `Get-DriveInfo.ps1` -> update `04-csv-reference.md` and the reference tables
  in the HTML
- **Validation rules** in `Start-VMConversion.ps1` -> update the pre-flight list
  in `01-phase1-conversion.md`
- **State file schema or Status values** in any orchestrator -> update the
  relevant phase doc
- **GraphQL mutations or the recovery point logic** in `Start-FLR.ps1` or
  `Start-SQLRestore.ps1` -> update `03-phase3-flr-sql.md`
- **Matching tolerance or skip rules** in `Initialize-VMDrives.ps1` -> update
  `02-phase2-drives.md`

The HTML is currently maintained by hand rather than generated from these files,
so a change needs applying in both places.

## Documented behaviors that are worth revisiting in code

These are described accurately in the docs, but flagged here as candidates for
fixing rather than documenting forever.

| Area | Behavior |
|---|---|
| `Start-FLR.ps1` | Status polling correlates on the source host FID, not `AsyncRequestId`. Concurrent recoveries against one source host can report each other's status. |
| `Start-FLR.ps1` | `lastUpdatedTimeGt` is passed local time while `Start-SQLRestore.ps1` uses ISO-8601 UTC. Inconsistent, and skews the event window on a non-UTC host. |
| `Start-SQLRestore.ps1` | Event query filters on `objectType = Mssql` only, with no instance FID scoping, so concurrent SQL jobs contaminate each other's status. |
| `Initialize-VMDrives.ps1` | `PartitionsOnDisk` is read into a feature flag that is never used. Grouping relies solely on `DiskNumber`. |
| `Initialize-VMDrives.ps1` | Multi-partition target size falls back to summed capacity times `1.05` while the adjacent comment says 10 percent. |
| `Convert-VMDK-to-VHD.ps1` | Rewrites the downloaded `.vmdk` descriptor in place rather than working on a copy, so a re-run against an already-converted download directory is not clean. |
| `Get-RubrikVMDKList.ps1` | `DriveLetter` is merged forward but consumed by nothing. Either wire it up or drop it. |
