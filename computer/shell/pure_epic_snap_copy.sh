#!/bin/bash
# For AIX: change the shebang above to #!/bin/ksh and set PLATFORM="aix" below

# Pure Storage Snap and Copy Script for Epic IRIS ODB
# Updated: 4/26/26
#
# Purpose:
#   Automates the Pure Storage protection group snapshot and volume copy workflow
#   for Epic IRIS ODB environments. Designed to run on a backup proxy host that
#   receives copied volumes from the Pure array.
#
# Platform Support:
#   This script supports both Linux (bash) and AIX (ksh) environments.
#   - Linux (default): Set PLATFORM="linux" (or leave as default)
#   - AIX: Change the shebang to #!/bin/ksh and set PLATFORM="aix"
#   If PLATFORM is not explicitly set, the script auto-detects via uname.
#   Platform-specific commands (LVM, SCSI rescan, mount options) are branched
#   automatically based on the PLATFORM variable.
#
# Usage:
#   1. Configure all variables in the VARIABLES section below
#   2. Ensure SSH public key authentication is set up:
#      - Backup proxy -> Pure Array (PURE_USER)
#      - Backup proxy -> Epic IRIS ODB host (EPIC_ID) [if EXECUTE_EPIC=true]
#   3. Create a "logs" subdirectory under SNAPDIR: mkdir -p ${SNAPDIR}/logs
#   4. Run: ./pure_epic_snap_copy.sh
#   5. Optionally schedule via cron for automated execution
#
# Workflow:
#   1. Check lock file to prevent concurrent runs
#   2. Unmount backup filesystems on proxy host
#   3. Deactivate and export volume group (if EXECUTE_LVM=true)
#        - Linux: vgchange -a n / vgexport
#        - AIX:   varyoffvg / exportvg
#   4. Destroy existing Pure PG snapshots matching the Rubrik suffix
#   5. Freeze Epic IRIS cache (set EXECUTE_EPIC=false to skip)
#        - AIX: also freezes JFS2 filesystems (if EXECUTE_JFS2=true)
#   6. Start auto-thaw timer as safety net (8 min timeout)
#   7. Create new PG snapshot with date-stamped suffix
#   8. Thaw Epic IRIS cache (set EXECUTE_EPIC=false to skip)
#        - AIX: also thaws JFS2 filesystems (if EXECUTE_JFS2=true)
#   9. Copy snapshot volumes to target (backup proxy) volumes
#  10. SCSI/device rescan and reimport volume group (if EXECUTE_LVM=true)
#        - Linux: rescan-scsi-bus.sh / pvscan / vgimport / vgchange -a y
#        - AIX:   cfgmgr / importvg / varyonvg
#  11. Mount backup filesystems on proxy host
#        - Linux: mount <dev> <mount_point>
#        - AIX:   mount -o cio <dev> <mount_point>
#
#   The freeze window (steps 5-8) is kept as tight as possible — unmount,
#   LVM teardown, and snap cleanup all happen before the freeze so that
#   Epic is only frozen for the duration of the snapshot itself.
#
# Throughput & Timing:
#   The total script runtime depends on several factors:
#   - Freeze/thaw:   Typically completes in seconds. The freeze window (time
#                     between instfreeze and instthaw) should be < 1 minute.
#                     Auto-thaw safety net fires at 8 minutes if thaw fails.
#   - PG snapshot:   Near-instant. Pure snapshots are metadata-only operations
#                     and do not copy data — they are space-efficient pointers.
#   - Volume copy:   Array-internal operation at ~GB/s throughput. Duration
#                     scales with the number and size of volumes. The --overwrite
#                     flag leverages dedup-aware copying so only changed blocks
#                     are written. Expect seconds to low minutes per volume for
#                     typical Epic ODB sizes (100s of GB each).
#   - SCSI rescan:   Seconds. Needed only if LVM teardown/reimport is enabled.
#   - Mount/unmount: Seconds per filesystem.
#   - Overall:       For a typical Epic environment with 1-4 ODB volumes,
#                     expect 2-5 minutes total. Larger environments with many
#                     volumes or multi-TB sizes may take longer due to copy time.
#
# SSH Key Setup:
#   Ensure that the SSH public key of the backup proxy host is configured on
#   the Pure Array and the Epic IRIS ODB host under the appropriate users.
#   - Backup proxy SSH public key is similar to: ~/.ssh/id_rsa.pub
#   - Pure Array add to: Settings -> Access -> Users -> "..." -> Edit User -> Public Key
#   - IRIS ODB host add to: ~/.ssh/authorized_keys
#
# For AIX: When copying LUNs for the first time to the proxy host:
#   1. "lspv" - display all physical disks
#   2. "chdev -l hdisk4 -a pv=yes" - create a PV from the disk
#   3. "importvg -y vgprd01 hdisk4" - import pre-existing VG info
#   4. "lsvg" & "lsvg -p <vg_name>" - check VG info
#   5. "lsvg -l <vg_name>" - list all LV under a VG
#   6. "lslv <lv_name>" - check LV info
#   7. "lsfs | grep <lv_name>" - check file system info on LV
#   8. "mount -o cio /dev/<lv_name> <mount_point>" - mount the LV to a mount point w/'cio'
#
# For Linux: When copying LUNs for the first time to the proxy host:
#   1. "lsblk" - display all physical disks
#   2. "blkid </dev/sdb>>" - Check the physical disk signature to confirm LVM
#   3. "lvmdevices --adddev /dev/sdb" - Add the device to be discoverable
#   4. "cat /etc/lvm/devices/system.devices" - Check that the device is added
#   5. "pvscan" - Scan for new PVs
#   6. "pvs", "lvs", "vgs" - check PV, LV, VG info
#   7. "vgchange -ay" - Active discovered VGs
#   8. "ls -l /dev/mapper" - Find device mapper paths for LVs
#   9. "mount /dev/mapper/prdvg-prd01 /epic/prd01" - Mount the LV to a mount point


### VARIABLES - BEGIN ###

# Platform: "linux" or "aix"
# If not set, auto-detects via uname. For AIX, also change the shebang to #!/bin/ksh
PLATFORM=""

# Toggle to control whether Epic freeze/thaw commands are executed
EXECUTE_EPIC="true"

# Toggle to control whether LVM/VG teardown/reimport and device rescan are performed
# Enable this if the backup proxy requires vgexport/vgimport (Linux) or
# exportvg/importvg (AIX) between refreshes
EXECUTE_LVM="false"

# Toggle to control whether JFS2 filesystem freeze/thaw is executed (AIX only)
# Enable this if the AIX proxy uses JFS2 filesystems that need freezing
EXECUTE_JFS2="false"

# Directory where script files will be located and run from
SNAPDIR="."

# Current date time & location of the logfile
LAUNCHTIME=$(date +%Y-%m-%d_%H%M)
LOGFILE="${SNAPDIR}/logs/puresnaplog-${LAUNCHTIME}.log"
touch "$LOGFILE"

# Lock file to check if the script is already running
REFRESH_LOCK_FILE="${SNAPDIR}/puresnaplockfile"

# Pure array hostname and username
PURE_ARRAY="<ip_or_hostname_of_pure_array>"
PURE_USER="<pure_ssh_user>"

# Pure - Name of the Protection Group that the IRIS volumes belong to
SOURCE_PG_GROUP="Epic-PGPROD"
# Pure - This suffix will be appended to the PG Snap along with YYYY.MM.DD
#  <SOURCE_PG_GROUP>.<SOURCE_SNAP_SUFFIX>-YYYY-MM-DD
SOURCE_SNAP_SUFFIX="rubriksnap"
# Pure - Source IRIS volumes - The naming prefix, with a suffix of "##"
SOURCE_VOL_PREFIX="epic_iris_odb_source_vol_"
# Pure - Target IRIS volumes - The naming prefix, with a suffix of "##"
TARGET_VOL_PREFIX="epic_iris_odb_proxy_vol_"

# The mount point details for the backup proxy
# The base of the mount points on the file system
MOUNT_BASE='/epic'
# Sub-directories under the base mount point, comma separated
MOUNT_POINTS="/prd01"
# The /dev/<lv_name> that will be mounted to each mount point, comma separated
# Linux example: /dev/mapper/prdvg-prd01
# AIX example:   /dev/prd01lv
DEV_LV="/dev/mapper/prdvg-prd01"

# Volume group name (used when EXECUTE_LVM=true)
LVM_VG="prdvg"
# Physical disk for VG import (AIX only, used when EXECUTE_LVM=true)
# On AIX, after exportvg the VG-to-disk mapping is removed from ODM,
# so lspv cannot auto-discover the disk. Specify the hdisk name here.
# Find it with: lspv | grep <vg_name>  (before running exportvg)
AIX_VG_HDISK="hdisk1"

# Variables for Epic application
EPIC_FREEZE_CMD="/epic/sup/bin/instfreeze"
EPIC_THAW_CMD="/epic/sup/bin/instthaw"
EPIC_AUTOTHAW_CMD="nohup sh -c '(sleep 8m && ${EPIC_THAW_CMD}) > /dev/null 2>&1 &'"
EPIC_SERVER="mbepicrel"
EPIC_ID="root"

# JFS2 freeze/thaw commands (AIX only, used when EXECUTE_JFS2=true)
# Update the filesystem paths to match the AIX environment
JFS2_FREEZE_CMD="chfs -a freeze=60 /epic/sup01 ; chfs -a freeze=60 /epic/sup02 ; chfs -a freeze=60 /epic/sup03 ; chfs -a freeze=60 /epic/sup04"
JFS2_THAW_CMD="chfs -a freeze=off /epic/sup01 ; chfs -a freeze=off /epic/sup02 ; chfs -a freeze=off /epic/sup03 ; chfs -a freeze=off /epic/sup04"
JFS2_AUTOTHAW_CMD="nohup sh -c '(sleep 1m && ${JFS2_THAW_CMD}) > /dev/null 2>&1 &'"

### VARIABLES - END ###

# Auto-detect platform if not explicitly set
if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        AIX)   PLATFORM="aix" ;;
        *)     PLATFORM="linux" ;;
    esac
fi

# pipefail is available in bash but not all ksh versions
if [ "$PLATFORM" = "linux" ]; then
    set -o pipefail
fi

# Track whether freeze was executed so exit_failed can attempt thaw
FREEZE_EXECUTED="false"
# Track elapsed time (SECONDS is a bash/ksh93 built-in)
SECONDS=0

exit_failed() {
    # If Epic was frozen, attempt a thaw before exiting
    if [ "$EXECUTE_EPIC" = "true" ] && [ "$FREEZE_EXECUTED" = "true" ]; then
        echo "Attempting Epic IRIS thaw before exit..." | tee -a "${LOGFILE}"
        /usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_THAW_CMD} 2>&1 | tee -a "${LOGFILE}"
    fi
    # SUBJECT="AUTOMATED EMAIL: $(hostname): Epic IRIS ODB Pure Snap Script Failed"
    # EMAILMSG="The Pure Snap and Copy script failed.  Please review the log output"
    # EMAILLOG=$(cat ${LOGFILE})
    # EMAILBODY=${EMAILMSG}${EMAILLOG}
    # FN_email_log ${ADMINEMAILS} ${SUBJECT} ${EMAILBODY}
    ELAPSED=$SECONDS
    echo "Script FAILED after $((ELAPSED / 60))m $((ELAPSED % 60))s on $(date)" | tee -a "${LOGFILE}"
    rm -f "$REFRESH_LOCK_FILE"
    exit 1
}

echo "Starting Pure IRIS ODB snap refresh script on $(hostname)" | tee -a "${LOGFILE}"
echo "Current date is: $(date)" | tee -a "${LOGFILE}"
echo "Platform: ${PLATFORM}" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

# Check if there is an existing lock file, if so then exit
if [ -f "${REFRESH_LOCK_FILE}" ]; then
    echo "Terminating script, refresh process is already running." | tee -a "${LOGFILE}"
    echo "Removing the lockfile and exiting.  Please check $LOGFILE" | tee -a "${LOGFILE}"
    exit_failed
else
    echo "Creating lock file for current run." | tee -a "${LOGFILE}"
    echo "" | tee -a "${LOGFILE}"
    date > "${REFRESH_LOCK_FILE}"
fi

# Initialize the mount point arrays based on platform/shell
if [ "$PLATFORM" = "aix" ]; then
    echo "Defining mount point arrays for KornShell (AIX)..." | tee -a "${LOGFILE}"
    IFS=',' set -A MOUNT_POINTS_ARRAY $MOUNT_POINTS
    IFS=',' set -A DEV_LV_ARRAY $DEV_LV
else
    echo "Defining mount point arrays for Bash (Linux)..." | tee -a "${LOGFILE}"
    IFS=','
    MOUNT_POINTS_ARRAY=($MOUNT_POINTS)
    DEV_LV_ARRAY=($DEV_LV)
fi
echo "" | tee -a "${LOGFILE}"

IFS=$' \t\n'  # Restore IFS to its default value

########################################################################################################
# Unmount backup filesystems
# Done before freeze to keep the freeze window as tight as possible.
# Also ensures that if the script fails to re-mount, a backup job will fail
# (no files found) rather than backing up stale data.
########################################################################################################

ARRAY_LENGTH=${#MOUNT_POINTS_ARRAY[@]}
i=0
while [ $i -lt $ARRAY_LENGTH ]; do
    MOUNT_POINT="${MOUNT_BASE}${MOUNT_POINTS_ARRAY[i]}"
    echo "Unmounting: ${MOUNT_POINT}" | tee -a "${LOGFILE}"
    umount "${MOUNT_POINT}"
    if [ $? -ne 0 ]; then
        echo "WARNING: Unable to unmount ${MOUNT_POINT}" | tee -a "${LOGFILE}"
    fi
    i=$((i + 1))
done
echo "" | tee -a "${LOGFILE}"

########################################################################################################
# Volume group teardown (optional) - deactivate and export
# Done before freeze to keep the freeze window as tight as possible.
# Linux: vgchange -a n / vgexport
# AIX:   varyoffvg / exportvg
########################################################################################################

if [ "$EXECUTE_LVM" = "true" ]; then
    if [ "$PLATFORM" = "aix" ]; then
        echo "Varying off volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        varyoffvg "${LVM_VG}"
        RC=$?
        if [ $RC -eq 0 ]; then
            echo "SUCCESSFUL varyoffvg ${LVM_VG}" | tee -a "${LOGFILE}"
        else
            echo "WARNING: varyoffvg ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi

        echo "Exporting volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        exportvg "${LVM_VG}"
        RC=$?
        if [ $RC -eq 0 ]; then
            echo "SUCCESSFUL exportvg ${LVM_VG}" | tee -a "${LOGFILE}"
        else
            echo "WARNING: exportvg ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
    else
        echo "Deactivating volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        vgchange -a n "${LVM_VG}"
        RC=$?
        if [ $RC -eq 0 ]; then
            echo "SUCCESSFUL vgchange -a n ${LVM_VG}" | tee -a "${LOGFILE}"
        else
            echo "WARNING: vgchange -a n ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi

        echo "Exporting volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        vgexport "${LVM_VG}"
        RC=$?
        if [ $RC -eq 0 ]; then
            echo "SUCCESSFUL vgexport ${LVM_VG}" | tee -a "${LOGFILE}"
        else
            echo "WARNING: vgexport ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
    fi
    echo "" | tee -a "${LOGFILE}"
fi

########################################################################################################
# Pure Storage - Get PG volume info and destroy old snapshots
# Done before freeze to keep the freeze window as tight as possible.
########################################################################################################

echo "Starting Pure snap and copy process." | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

echo "Getting volume information for PG: ${SOURCE_PG_GROUP}" | tee -a "${LOGFILE}"
echo "Running Pure CLI: purepgroup list ${SOURCE_PG_GROUP} --nvp" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

PGOUTPUT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup list ${SOURCE_PG_GROUP} --nvp")

if [ -z "${PGOUTPUT}" ]; then
    echo "PG invalid or did not find any LUNs for PG: ${SOURCE_PG_GROUP}, exiting..." | tee -a "${LOGFILE}"
    exit_failed
fi

PGVOLUMES=$(echo "$PGOUTPUT" | sed -n 's/.*Volumes=//p')
echo "$PGVOLUMES" > "${SNAPDIR}/volumes.txt"
echo "Found volumes for PG: ${SOURCE_PG_GROUP}" | tee -a "${LOGFILE}"
echo "${PGVOLUMES}" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

echo "Checking for existing Rubrik PG snaps to destroy." | tee -a "${LOGFILE}"
echo "Running Pure CLI: purepgroup list ${SOURCE_PG_GROUP} --snap --notitle" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"
PGSNAPLIST=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup list ${SOURCE_PG_GROUP} --snap --notitle")
RUBRIKSNAPS=$(echo "$PGSNAPLIST" | grep "$SOURCE_SNAP_SUFFIX")

if [ -z "$RUBRIKSNAPS" ]; then
    echo "No PG snapshots found matching ${SOURCE_SNAP_SUFFIX}." | tee -a "${LOGFILE}"
    echo "" | tee -a "${LOGFILE}"
else
    echo "Found the following PG snapshot(s) with Rubrik suffix: ${SOURCE_SNAP_SUFFIX}" | tee -a "${LOGFILE}"
    echo "${RUBRIKSNAPS}" | tee -a "${LOGFILE}"
    echo "" | tee -a "${LOGFILE}"
    IFS='
'
    for SNAP in $RUBRIKSNAPS; do
        SNAPNAME=$(echo "$SNAP" | awk '{print $1}')
        echo "Running Pure CLI: purepgroup destroy ${SNAPNAME}" | tee -a "${LOGFILE}"
        PGSNAPDESTROYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup destroy ${SNAPNAME}" 2>&1)
        if ! echo "$PGSNAPDESTROYRESULT" | grep -q "Name"; then
            echo "Failed destroying PG snapshot: ${SNAPNAME}" | tee -a "${LOGFILE}"
        else
            echo "Successfully destroyed PG snapshot, SafeMode will handle eradication" | tee -a "${LOGFILE}"
            echo "${PGSNAPDESTROYRESULT}" | tee -a "${LOGFILE}"
            echo "" | tee -a "${LOGFILE}"
        fi
    done
    IFS=$' \t\n'  # Restore IFS to its default value
fi

# Prepare the snapshot suffix before entering the freeze window
CURRENT_DATE=$(date +%Y-%m-%d)
PG_SNAP_SUFFIX="${SOURCE_SNAP_SUFFIX}-${CURRENT_DATE}"

########################################################################################################
# Freeze Epic IRIS cache
# The freeze window starts here and ends at thaw. Only the PG snapshot is
# taken while frozen — everything else runs outside the window.
# AIX: optionally also freezes JFS2 filesystems if EXECUTE_JFS2=true.
########################################################################################################

if [ "$EXECUTE_EPIC" = "true" ]; then
    echo "Sending out commands to freeze IRIS ODB" | tee -a "${LOGFILE}"
    EPIC_FREEZE_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_FREEZE_CMD} 2>&1)
    if [ $? -eq 0 ]; then
        FREEZE_EXECUTED="true"
        FREEZE_START=$SECONDS
        echo "IRIS successfully frozen on $(date)" | tee -a "${LOGFILE}"
    else
        echo "ERROR: Unable to freeze IRIS: ${EPIC_FREEZE_RESULT}" | tee -a "${LOGFILE}"
        exit_failed
    fi
    echo "Starting auto-thaw safety timer (8 min)" | tee -a "${LOGFILE}"
    EPIC_AUTOTHAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1)

    # JFS2 freeze (AIX only) - freezes JFS2 filesystems with a 60-second auto-thaw
    if [ "$PLATFORM" = "aix" ] && [ "$EXECUTE_JFS2" = "true" ]; then
        echo "Freezing JFS2 filesystems" | tee -a "${LOGFILE}"
        JFS_FREEZE_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} "${JFS2_FREEZE_CMD}" 2>&1)
        echo "JFS2 freeze result: ${JFS_FREEZE_RESULT}" | tee -a "${LOGFILE}"
        echo "Starting JFS2 auto-thaw safety timer (1 min)" | tee -a "${LOGFILE}"
        JFS_AUTOTHAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} "${JFS2_AUTOTHAW_CMD}" 2>&1)
    fi
fi

########################################################################################################
# Create PG snapshot (this is the only operation inside the freeze window)
########################################################################################################

echo "Creating PG snapshot of PG: ${SOURCE_PG_GROUP}" | tee -a "${LOGFILE}"
echo "PG snapshot suffix will be: ${PG_SNAP_SUFFIX}" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

echo "Running Pure CLI: purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}" | tee -a "${LOGFILE}"
PGSNAPRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}" 2>&1)

if ! echo "$PGSNAPRESULT" | grep -q "Created"; then
    echo "Failed creating PG snapshot: ${PGSNAPRESULT}, exiting..." | tee -a "${LOGFILE}"
    exit_failed
fi

echo "${PGSNAPRESULT}" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

########################################################################################################
# Thaw Epic IRIS (end of freeze window)
########################################################################################################

if [ "$EXECUTE_EPIC" = "true" ]; then
    # JFS2 thaw (AIX only) - thaw JFS2 filesystems first
    if [ "$PLATFORM" = "aix" ] && [ "$EXECUTE_JFS2" = "true" ]; then
        echo "Thawing JFS2 filesystems" | tee -a "${LOGFILE}"
        JFS2_THAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} "${JFS2_THAW_CMD}" 2>&1)
        echo "JFS2 thaw result: ${JFS2_THAW_RESULT}" | tee -a "${LOGFILE}"
    fi

    echo "Sending out commands to thaw IRIS ODB" | tee -a "${LOGFILE}"
    EPIC_THAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_THAW_CMD} 2>&1)
    if [ $? -eq 0 ]; then
        FREEZE_EXECUTED="false"
        if [ -n "$FREEZE_START" ]; then
            FREEZE_DURATION=$((SECONDS - FREEZE_START))
            echo "IRIS successfully thawed on $(date) (freeze window: ${FREEZE_DURATION}s)" | tee -a "${LOGFILE}"
        else
            echo "IRIS successfully thawed on $(date)" | tee -a "${LOGFILE}"
        fi
    else
        echo "ERROR: Unable to thaw IRIS: ${EPIC_THAW_RESULT}" | tee -a "${LOGFILE}"
        echo "WARNING: Auto-thaw safety timer should handle thaw within 8 minutes" | tee -a "${LOGFILE}"
    fi
fi

########################################################################################################
# Copy snapshot volumes to target volumes
########################################################################################################

echo "Copying source volumes to target volumes" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"
echo "Source volumes: ${PGVOLUMES}" | tee -a "${LOGFILE}"
echo "Source volume prefix: ${SOURCE_VOL_PREFIX}" | tee -a "${LOGFILE}"
echo "Target volume prefix: ${TARGET_VOL_PREFIX}" | tee -a "${LOGFILE}"
echo "For each source volume, the source prefix will be replaced with target prefix" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

IFS=','
for SOURCE_VOL in $PGVOLUMES; do
    echo "${SOURCE_VOL}" | tee -a "${LOGFILE}"
    TARGET_VOL=$(echo "$SOURCE_VOL" | sed "s|^$SOURCE_VOL_PREFIX|$TARGET_VOL_PREFIX|")
    echo "Copying source volume: $SOURCE_VOL to target volume: $TARGET_VOL" | tee -a "${LOGFILE}"
    echo "Running Pure CLI: purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force" | tee -a "${LOGFILE}"
    COPYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force" 2>&1)
    if ! echo "$COPYRESULT" | grep -q "Created"; then
        echo "Failed copy volume: ${COPYRESULT}, exiting..." | tee -a "${LOGFILE}"
        exit_failed
    fi
    echo "$COPYRESULT" | tee -a "${LOGFILE}"
    echo "" | tee -a "${LOGFILE}"
done
IFS=$' \t\n'  # Restore IFS to its default value

########################################################################################################
# Volume group reimport (optional) - device rescan, reimport, and activate
# Linux: rescan-scsi-bus.sh / pvscan / vgimport / vgchange -a y
# AIX:   cfgmgr / importvg / varyonvg
########################################################################################################

if [ "$EXECUTE_LVM" = "true" ]; then
    if [ "$PLATFORM" = "aix" ]; then
        echo "Rescanning devices (cfgmgr)..." | tee -a "${LOGFILE}"
        cfgmgr
        RC=$?
        if [ $RC -ne 0 ]; then
            echo "WARNING: cfgmgr failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
        echo "SUCCESSFUL cfgmgr" | tee -a "${LOGFILE}"

        echo "Importing volume group: ${LVM_VG} from ${AIX_VG_HDISK}" | tee -a "${LOGFILE}"
        importvg -y "${LVM_VG}" "${AIX_VG_HDISK}"
        RC=$?
        if [ $RC -ne 0 ]; then
            echo "WARNING: importvg ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
        echo "SUCCESSFUL importvg ${LVM_VG}" | tee -a "${LOGFILE}"

        echo "Varying on volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        varyonvg "${LVM_VG}"
        RC=$?
        if [ $RC -ne 0 ]; then
            echo "WARNING: varyonvg ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
        echo "SUCCESSFUL varyonvg ${LVM_VG}" | tee -a "${LOGFILE}"
    else
        echo "Rescanning SCSI bus for updated volumes..." | tee -a "${LOGFILE}"
        rescan-scsi-bus.sh
        RC=$?
        if [ $RC -ne 0 ]; then
            echo "WARNING: Unable to run rescan-scsi-bus.sh (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi

        echo "Running pvscan..." | tee -a "${LOGFILE}"
        pvscan
        RC=$?
        if [ $RC -ne 0 ]; then
            echo "WARNING: Unable to run pvscan (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi

        echo "Importing volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        vgimport -v "${LVM_VG}"
        RC=$?
        if [ $RC -ne 0 ] && [ $RC -ne 5 ]; then
            echo "WARNING: vgimport ${LVM_VG} failed (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
        echo "SUCCESSFUL vgimport ${LVM_VG}" | tee -a "${LOGFILE}"

        echo "Activating volume group: ${LVM_VG}" | tee -a "${LOGFILE}"
        vgchange -a y "${LVM_VG}"
        RC=$?
        if [ $RC -ne 0 ]; then
            echo "WARNING: Unable to run vgchange -a y ${LVM_VG} (rc=$RC)" | tee -a "${LOGFILE}"
            exit_failed
        fi
        echo "SUCCESSFUL vgchange -a y ${LVM_VG}" | tee -a "${LOGFILE}"
    fi
    echo "" | tee -a "${LOGFILE}"
fi

########################################################################################################
# Mount backup filesystems
# Linux: standard mount
# AIX:   mount with -o cio (Concurrent I/O for Epic)
########################################################################################################

echo "Mount Base: $MOUNT_BASE" | tee -a "${LOGFILE}"
echo "Mount Points Array: ${MOUNT_POINTS}" | tee -a "${LOGFILE}"
echo "Device Logical Volumes Array: ${DEV_LV}" | tee -a "${LOGFILE}"

ARRAY_LENGTH=${#MOUNT_POINTS_ARRAY[@]}
i=0
while [ $i -lt $ARRAY_LENGTH ]; do
    MOUNT_POINT="${MOUNT_BASE}${MOUNT_POINTS_ARRAY[i]}"
    DEV="${DEV_LV_ARRAY[i]}"
    echo "Mounting: ${DEV} to: ${MOUNT_POINT}" | tee -a "${LOGFILE}"
    if [ "$PLATFORM" = "aix" ]; then
        mount -o cio ${DEV} ${MOUNT_POINT}
    else
        mount ${DEV} ${MOUNT_POINT}
    fi
    if mount | grep "$MOUNT_POINT" >/dev/null 2>&1; then
        echo "Verified: ${MOUNT_POINT} is mounted successfully." | tee -a "${LOGFILE}"
    else
        echo "ERROR: ${MOUNT_POINT} does not appear mounted, exiting..." | tee -a "${LOGFILE}"
        exit_failed
    fi
    i=$((i + 1))
done

########################################################################################################
# Script completion
########################################################################################################

ELAPSED=$SECONDS
echo "" | tee -a "${LOGFILE}"
echo "Start the backup process of the mounted filesystems" | tee -a "${LOGFILE}"
echo "Pure IRIS ODB snap refresh completed successfully on $(date) (total: $((ELAPSED / 60))m $((ELAPSED % 60))s)" | tee -a "${LOGFILE}"
rm -f "$REFRESH_LOCK_FILE"
exit 0
