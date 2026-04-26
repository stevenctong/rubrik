# Shell Scripts

Shell scripts for storage and backup automation workflows.

## Scripts

### pure_epic_snap_copy.sh

Automates the Pure Storage protection group snapshot and volume copy workflow for Epic IRIS ODB environments. Designed to run on a backup proxy host that receives copied volumes from the Pure array.

**Platform Support:** Linux (bash) and AIX (ksh). Set the `PLATFORM` variable to `"linux"` or `"aix"`, or leave empty for auto-detection via `uname`. For AIX, also change the shebang to `#!/bin/ksh`.

**Workflow:**

1. Unmount backup filesystems on the proxy host
2. Deactivate and export the volume group (optional, via `EXECUTE_LVM`)
3. Destroy existing Pure PG snapshots matching the configured suffix
4. Freeze Epic IRIS cache (optional, via `EXECUTE_EPIC`); AIX can also freeze JFS2 filesystems (`EXECUTE_JFS2`)
5. Create a new PG snapshot with a date-stamped suffix
6. Thaw Epic IRIS cache
7. Copy snapshot volumes to target (backup proxy) volumes
8. SCSI/device rescan and reimport the volume group (optional)
9. Mount backup filesystems on the proxy host

The freeze window is minimized — only the PG snapshot is taken while the cache is frozen. All other operations (unmount, LVM teardown, snap cleanup, volume copy, remount) run outside the freeze window.

**Key Features:**

- Lock file prevents concurrent runs
- Auto-thaw safety timer (8 min) protects against stuck freezes
- `exit_failed()` attempts Epic thaw on any script failure
- Dual console + logfile output via `tee`
- Elapsed time tracking with freeze window duration logged
- SafeMode-aware snap cleanup (destroy only, no eradicate)
- Platform-branched LVM/VG commands, SCSI rescan, and mount options

**Configuration:**

All variables are in the `### VARIABLES ###` block at the top of the script. Key toggles:

| Variable | Default | Description |
|---|---|---|
| `PLATFORM` | `""` (auto-detect) | `"linux"` or `"aix"` |
| `EXECUTE_EPIC` | `"false"` | Enable Epic IRIS freeze/thaw |
| `EXECUTE_LVM` | `"false"` | Enable VG teardown/reimport and device rescan |
| `EXECUTE_JFS2` | `"false"` | Enable JFS2 freeze/thaw (AIX only) |

**Prerequisites:**

- SSH public key authentication from the backup proxy to the Pure array and the Epic IRIS ODB host
- A `logs/` subdirectory under the script's directory for log output
- Pure CLI access on the array (via SSH)
