#!/bin/bash
#
# Author: Steven Tong (Rubrik)
# Date Updated: 7/13/26
#
# Description:
# Refreshes Epic IRIS ODB volumes on a Proxy VM by creating a Pure Storage
# Protection Group (PG) snapshot and copying the volumes to the target volumes.
# The script dynamically discovers source volumes from the PG and maps them
# to target volumes by replacing the SOURCE_VOL_PREFIX with TARGET_VOL_PREFIX
# (the volume number suffix carries over automatically).
#
# The script unmounts the target, destroys any previous PG snapshots with the
# configured suffix, creates a new PG snapshot, optionally freezes/thaws the
# Epic IRIS instance, copies the snapshots to the target volumes, and re-mounts.
#
# Usage:
#   ./pure_epic_snap_copy.sh
#
# Script should be in a location that contains: "/rubrik/scripts" in the path
# Script location can be defined at: ${SNAPDIR}
# Create a sub-directory "/logs" under ${SNAPDIR} for logs
#
# Setup: Configuring the Proxy VM Target Volumes (TARGET_VOL_PREFIX)
# The first snapshot copy will auto-create the target volumes on the Pure array.
# After the volumes are created, you still need to map and attach them:
# 1. Run the script once to create the PG snapshot and copy to target volumes
#    (the copy command auto-creates the target volumes on the Pure array)
# 2. Map the new volumes to the host or host group of the ESXi cluster that the
#    Proxy VM resides on
# 3. Attach the new volumes as Raw Device Mappings (RDM) to the Proxy VM
# 4. Set "TARGET_VOL_PREFIX" to the naming prefix of these volumes
# 5. For first-time setup on the Proxy VM, follow the Linux or AIX steps below
#    to discover, activate, and mount the LUN
# On subsequent runs, the target volumes already exist and are overwritten in place.
#
# Setup: SSH Key Configuration
# The Proxy VM uses SSH to run commands on the Pure array and the Epic IRIS ODB
# host. Copy the Proxy VM's public key (~/.ssh/id_rsa.pub) to both targets:
# 1. Pure Array: Settings -> Access -> Users -> select user -> Edit User -> Public Key
# 2. IRIS ODB host: append to ~/.ssh/authorized_keys for the EPIC_ID user
#
# For AIX: When copying LUNs for the first time to the proxy host:
# 1. "lspv" - display all physical disks
# 2. "chdev -l hdisk4 -a pv=yes" - create a PV from the disk
# 3. "importvg -y vgprd01 hdisk4" - import pre-existing VG info
# 4. "lsvg" & "lsvg -p <vg_name>" - check VG info
# 5. "lsvg -l <vg_name>" - list all LV under a VG
# 6. "lslv <lv_name>" - check LV info
# 7. "lsfs | grep <lv_name>" - check file system info on LV
# 8. "mount -o cio /dev/<lv_name> <mount_point>" - mount the LV to a mount point w/'cio'
#
# For Linux: When copying LUNs for the first time to the proxy host:
# 1. "echo 1 > /sys/block/sdaf/device/rescan" - rescan the physical volumes
# 2. "lsblk" - display all physical disks, confirm size
# 3. "blkid </dev/sdb>" - check the physical disk signature to confirm LVM
# 4. "pvresize /dev/sdaf" - resize the PV to what it should be
# 5. "pvs /dev/sdaf" - get the name of the volume group on the PV
# 6. "vgchange -an epicdctstvg" - vary off the volume group
# 7. "vgchange -ay epicdctstvg" - vary on the volume group
# 8. "ls -l /dev/mapper" - find the device mapper paths for LVs
# 9. "mount /dev/mapper/epicdctstvg-dctstlv001 /mnt/dctst" - mount the LV to a mount point

### VARIABLES - BEGIN ###

### Instance-specific variables - BEGIN ###

# Name of the Epic instance (used in log filenames)
INSTANCE_NAME="epic_instance"

# Whether or not to execute the Epic IRIS freeze / thaw for testing
EXECUTE_EPIC="false"
# Set to "false" to dry-run the script without executing Pure commands
# Useful for validating volume prefix replacements and script flow
EXECUTE_PURE="false"

# Pure array hostname and username
PURE_ARRAY="sjc-rcf-pure04.stor.rubrik.com"
PURE_USER="perf-admin"

# Pure - Name of the Protection Group that the IRIS volumes belong to
SOURCE_PG_GROUP="pg-epic"
# Pure - This suffix will be appended to the PG Snap along with YYYY-MM-DD-HHMM
#  <SOURCE_PG_GROUP>.<SOURCE_SNAP_SUFFIX>-YYYY-MM-DD-HHMM
SOURCE_SNAP_SUFFIX="rubriksnap"
# Pure - Source IRIS volumes naming prefix (volumes are discovered from the PG)
# The script maps source to target by replacing SOURCE_VOL_PREFIX with TARGET_VOL_PREFIX
SOURCE_VOL_PREFIX="iris-sourcevol"

# Pure - Target IRIS volumes naming prefix on the Proxy VM
TARGET_VOL_PREFIX="iris-tgtvol-"

# The mount point details for the backup proxy
# The base of the mount points on the file system
MOUNT_BASE='/epic'
# Sub-directories under the base mount point, comma separated
MOUNT_POINTS="/prd01"
# The /dev/<lv_name> that will be mounted to each mount point, comma separated
DEV_LV="/dev/mapper/prdvg-prd01"

# Variables for Epic application
EPIC_FREEZE_CMD="/epic/sup/bin/instfreeze"
EPIC_THAW_CMD="/epic/sup/bin/instthaw"
EPIC_AUTOTHAW_CMD="nohup sh -c '(sleep 8m && ${EPIC_THAW_CMD}) > /dev/null 2>&1 &'"
EPIC_SERVER="mbepicrel"
EPIC_ID="root"

# JFS2_FREEZE_CMD="chfs -a freeze=60 /epic/sup01 ; chfs -a freeze=60 /epic/sup02 ; chfs -a freeze=60 /epic/sup03 ; chfs -a freeze=60 /epic/sup04"
# JFS2_THAW_CMD="chfs -a freeze=off /epic/sup01 ; chfs -a freeze=off /epic/sup02 ; chfs -a freeze=off /epic/sup03 ; chfs -a freeze=off /epic/sup04"
# JFS2_AUTOTHAW_CMD="nohup sh -c '(sleep 1m && ${JFS2_THAW_CMD}) > /dev/null 2>&1 &'"

### Instance-specific variables - END ###

# Check the shell that the script is currently running in
CURRENT_SHELL=$(ps -p $$ -o args=)

# Split comma-separated mount point lists into arrays
if [[ "$CURRENT_SHELL" == *ksh* ]]; then
    IFS=',' set -A MOUNT_POINTS_ARRAY $MOUNT_POINTS
    IFS=',' set -A DEV_LV_ARRAY $DEV_LV
else
    IFS=',' read -ra MOUNT_POINTS_ARRAY <<< "$MOUNT_POINTS"
    IFS=',' read -ra DEV_LV_ARRAY <<< "$DEV_LV"
fi
IFS=$' \t\n'

### Derived variables (not overridden) - BEGIN ###

# Directory where script files will be located and run from
SNAPDIR="."

# Lock file to check if the script is already running
REFRESH_LOCK_FILE="${SNAPDIR}/puresnaplockfile"

# Number of days of log files to keep, older logs will be deleted
LOG_RETENTION_DAYS=60

# Current date time & location of the logfile
LAUNCHTIME=$(date +%Y-%m-%d_%H%M)
LOGDIR="${SNAPDIR}/logs"
LOGFILE="${LOGDIR}/puresnaplog-${INSTANCE_NAME}-${LAUNCHTIME}.log"
mkdir -p "${LOGDIR}"
touch $LOGFILE

# Delete log files older than the retention period
DELETED_LOGS=$(find "${LOGDIR}" -name "puresnaplog-*.log" -type f -mtime +${LOG_RETENTION_DAYS} -print -exec rm -f {} \; 2>/dev/null)
if [[ -n "$DELETED_LOGS" ]]; then
  echo "Cleaned up log files older than ${LOG_RETENTION_DAYS} days:"
  echo "$DELETED_LOGS"
  echo ""
fi

### Derived variables (not overridden) - END ###

### VARIABLES - END ###

exit_failed() {
    # SUBJECT="AUTOMATED EMAIL: $(hostname): Epic IRIS ODB Pure Snap Script Failed"
    # EMAILMSG="The Pure Snap and Copy script failed.  Please review the log output"
    # EMAILLOG=`cat ${LOGFILE}`
    # EMAILBODY=${EMAILMSG}${EMAILLOG}
    #FN_email_log ${ADMINEMAILS} ${SUBJECT} ${EMAILBODY}
    rm $REFRESH_LOCK_FILE
    exit 1
}

# Redirect all output to both stdout and the log file (bash only, ksh does not support process substitution)
if [[ "$CURRENT_SHELL" != *ksh* ]]; then
  exec &> >(tee -a "${LOGFILE}")
fi

echo "Starting Pure IRIS ODB PG snap refresh script on $(hostname)"
echo "Current date is: $(date)"
echo "Currently running shell: ${CURRENT_SHELL}"
echo "Log file: ${LOGFILE}"
if [ "$EXECUTE_PURE" != "true" ]; then
  echo "*** DRY-RUN MODE: Pure commands will not be executed ***"
fi
echo ""

# Check if there is an existing lock file, if so then exit
if [ -f ${REFRESH_LOCK_FILE} ]; then
    echo "Terminating script, refresh process is already running."
    echo "Removing the lockfile and exiting.  Please check $LOGFILE"
    exit_failed
else
    echo "Creating lock file for current run."
    echo ""
    date > ${REFRESH_LOCK_FILE}
fi

if [ "$EXECUTE_EPIC" = "true" ]; then
  echo "Sending out commands to freeze IRIS ODB"
  EPIC_FREEZE_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_FREEZE_CMD} 2>&1)
  echo "EPIC Freeze Result: ${EPIC_FREEZE_RESULT}"
  EPIC_AUTOTHAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1)
  echo "EPIC Auto-Thaw Result: ${EPIC_AUTOTHAW_RESULT}"
  # Comment out the JFS2 pieces if on RHEL
  # JFS_FREEZE_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_FREEZE_CMD} 2>&1)
  # echo "JFS2 Freeze Result: ${JFS_FREEZE_RESULT}"
  # JFS_AUTOTHAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_AUTOTHAW_CMD} 2>&1)
  # echo "JFS2 Auto-Thaw Result: ${JFS_AUTOTHAW_RESULT}"
fi

# Un-mount the mount points. This will also ensure that if the script fails to
# complete a refresh and re-mount, then if a backup runs it will fail since no
# files will be found.

ARRAY_LENGTH=${#MOUNT_POINTS_ARRAY[@]}
i=0
while [ $i -lt $ARRAY_LENGTH ]; do
    MOUNT_POINT="${MOUNT_BASE}${MOUNT_POINTS_ARRAY[i]}"
    echo "Unmounting: ${MOUNT_POINT}"
    umount "${MOUNT_POINT}"
    i=$((i + 1))
done

echo ""
echo "Starting Pure PG snap and copy process."
echo ""

echo "Getting volume information for PG: ${SOURCE_PG_GROUP}"
echo "Running Pure CLI: purepgroup list ${SOURCE_PG_GROUP} --nvp"
echo ""

PGOUTPUT=$(/usr/bin/ssh -n ${PURE_USER}@${PURE_ARRAY} "purepgroup list ${SOURCE_PG_GROUP} --nvp")

if [[ -z "${PGOUTPUT}" ]]; then
  echo "PG invalid or did not find any LUNs for PG: ${SOURCE_PG_GROUP}, exiting..."
  exit_failed
fi

PGVOLUMES=$(echo "$PGOUTPUT" | sed -n 's/.*Volumes=//p')
echo "Found volumes for PG: ${SOURCE_PG_GROUP}"
echo ${PGVOLUMES}
echo ""

echo "Checking for existing PG snaps to destroy."
echo "Running Pure CLI: purepgroup list ${SOURCE_PG_GROUP} --snap --notitle"
echo ""
PGSNAPLIST=$(/usr/bin/ssh -n ${PURE_USER}@${PURE_ARRAY} "purepgroup list ${SOURCE_PG_GROUP} --snap --notitle")
RUBRIKSNAPS=$(echo "$PGSNAPLIST" | grep "$SOURCE_SNAP_SUFFIX")

if [[ -z "$RUBRIKSNAPS" ]]; then
  echo "No PG snapshots found matching ${SOURCE_SNAP_SUFFIX}."
  echo ""
else
  echo "Found the following PG snapshot(s) with suffix: ${SOURCE_SNAP_SUFFIX}"
  echo ${RUBRIKSNAPS}
  echo ""
  IFS=$'\n'
  for SNAP in $RUBRIKSNAPS; do
    SNAPNAME=$(echo "$SNAP" | awk '{print $1}')
    echo "Running Pure CLI: purepgroup destroy ${SNAPNAME}"
    if [ "$EXECUTE_PURE" = "true" ]; then
      PGSNAPDESTROYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup destroy ${SNAPNAME}" 2>&1)
      if ! echo "$PGSNAPDESTROYRESULT" | grep -q "Name"; then
        echo "Failed destroying PG snapshot: ${SNAPNAME}"
      else
        echo "Successfully destroyed PG snapshot, SafeMode will handle eradication"
        echo ${PGSNAPDESTROYRESULT}
        echo ""
      fi
    else
      echo "[DRY-RUN] Skipping: purepgroup destroy ${SNAPNAME}"
    fi
  done
  IFS=$' \t\n'
fi

echo "Creating PG snapshot of PG: ${SOURCE_PG_GROUP}"
CURRENT_DATE=$(date +%Y-%m-%d-%H%M)
PG_SNAP_SUFFIX="${SOURCE_SNAP_SUFFIX}-${CURRENT_DATE}"
echo "PG snapshot suffix will be: ${PG_SNAP_SUFFIX}"
echo ""

echo "Running Pure CLI: purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}"
if [ "$EXECUTE_PURE" = "true" ]; then
  PGSNAPRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}" 2>&1)
  if ! echo "$PGSNAPRESULT" | grep -q "Created"; then
    echo "Failed creating PG snapshot: ${PGSNAPRESULT}, exiting..."
    exit_failed
  fi
else
  echo "[DRY-RUN] Skipping: purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}"
  PGSNAPRESULT=""
fi

echo ${PGSNAPRESULT}
echo ""
sleep 3

if [ "$EXECUTE_EPIC" = "true" ]; then
  echo "Sending out commands to thaw IRIS ODB"
  # JFS2_THAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_THAW_CMD} 2>&1)
  # echo "JFS2 Thaw Result: ${JFS2_THAW_RESULT}"
  EPIC_THAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_THAW_CMD} 2>&1)
  echo "EPIC Thaw Result: ${EPIC_THAW_RESULT}"
fi

echo "Copying source volumes to target volumes"
echo ""
echo "Source volumes: ${PGVOLUMES}"
echo "Source volume prefix: ${SOURCE_VOL_PREFIX}"
echo "Target volume prefix: ${TARGET_VOL_PREFIX}"
echo "For each source volume, the source prefix will be replaced with target prefix"
echo ""

echo "$PGVOLUMES" | tr ',' '\n' | while read -r SOURCE_VOL; do
  TARGET_VOL=$(echo "$SOURCE_VOL" | sed "s|^$SOURCE_VOL_PREFIX|$TARGET_VOL_PREFIX|")
  if [ "$SOURCE_VOL" = "$TARGET_VOL" ]; then
    echo "ERROR: Source volume '$SOURCE_VOL' does not match SOURCE_VOL_PREFIX '$SOURCE_VOL_PREFIX'"
    echo "Target volume was not renamed and would overwrite the source: ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} -> ${TARGET_VOL}"
    echo "Aborting to prevent overwriting source volumes."
    exit_failed
  fi
  echo "Copying source volume: $SOURCE_VOL to target volume: $TARGET_VOL"
  echo "Running Pure CLI: purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force"
  if [ "$EXECUTE_PURE" = "true" ]; then
    COPYRESULT=$(/usr/bin/ssh -n ${PURE_USER}@${PURE_ARRAY} "purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force" 2>&1)
    if ! echo "$COPYRESULT" | grep -q "Created"; then
      echo "Failed copy volume: ${COPYRESULT}, exiting..."
      exit_failed
    fi
    echo "$COPYRESULT"
  else
    echo "[DRY-RUN] Skipping: purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force"
  fi
  echo ""
done

echo "Mounting file systems"
echo ""

ARRAY_LENGTH=${#MOUNT_POINTS_ARRAY[@]}
i=0
while [ $i -lt $ARRAY_LENGTH ]; do
    MOUNT_POINT="${MOUNT_BASE}${MOUNT_POINTS_ARRAY[i]}"
    DEV="${DEV_LV_ARRAY[i]}"
    echo "Mounting: ${DEV} to: ${MOUNT_POINT}"
    # mount -o cio ${DEV} ${MOUNT_POINT}
    mount ${DEV} ${MOUNT_POINT}
    if mount | grep "$MOUNT_POINT" >/dev/null 2>&1; then
      echo "Verified: ${MOUNT_POINT} is mounted successfully."
    else
        echo "ERROR: ${MOUNT_POINT} does not appear mounted, exiting..."
        exit_failed
    fi
    i=$((i + 1))
done

echo ""
echo "Script completed successfully."
rm $REFRESH_LOCK_FILE
exit 0
