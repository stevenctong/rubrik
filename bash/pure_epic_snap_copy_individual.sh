#!/bin/bash

# Script should be in location: ${SNAPDIR}
# Create a sub-directory "/logs" under ${SNAPDIR} for logs

# Ensure that the SSH public key of the backup proxy host is configured on
# the Pure Array and the Epic IRIS ODB host under the appropriate users.
# - Backup proxy SSH public key is similar to: ~/.ssh/id_rsa.pub
# - Pure Array add to: Settings -> Access -> Users -> "..." -> Edit User -> Public Key
# - IRIS ODB host add to: ~/.ssh/authorized_keys

# For AIX: When copying LUNs for the first time to the proxy host:
# 1. "lspv" - display all physical disks
# 2. "chdev -l hdisk4 -a pv=yes" - create a PV from the disk
# 3. "importvg -y vgprd01 hdisk4" - import pre-existing VG info
# 4. "lsvg" & "lsvg -p <vg_name>" - check VG info
# 5. "lsvg -l <vg_name>" - list all LV under a VG
# 6. "lslv <lv_name>" - check LV info
# 7. "lsfs | grep <lv_name>" - check file system info on LV
# 8. "mount -o cio /dev/<lv_name> <mount_point>" - mount the LV to a mount point w/'cio'

# For Linux: When copying LUNs for the first time to the proxy host:
# 1. "lsblk" - display all physical disks
# 2. "blkid </dev/sdb>>" - Check the physical disk signature to confirm LVM
# 3. "lvmdevices --adddev /dev/sdb" - Add the device to be discoverable
# 4. "cat /etc/lvm/devices/system.devices" - Check that the device is added
# 5. "pvscan" - Scan for new PVs
# 6. "pvs", "lvs", "vgs" - check PV, LV, VG info
# 7. "vgchange -ay" - Active discovered VGs
# 8. "ls -l /dev/mapper" - Find device mapper paths for LVs
# 9. "mount /dev/mapper/prdvg-prd01 /epic/prd01" - Mount the LV to a mount point


### VARIABLES - BEGIN ###

EXECUTE_EPIC="false"

# Directory where script files will be located and run from
SNAPDIR="."

# Lock file to check if the script is already running
REFRESH_LOCK_FILE="${SNAPDIR}/puresnaplockfile"

# Pure array hostname and username
PURE_ARRAY="sjc-rcf-pure04.stor.rubrik.com"
PURE_USER="perf-admin"

# Pure - Name of the IRIS Volume
SOURCE_VOLUME="iris_sourcevol"
# Pure - This suffix will be appended to the Volume Snap along with YYYY-MM-DD
#  <SOURCE_VOLUME>.<SOURCE_SNAP_SUFFIX>-YYYY-MM-DD
SOURCE_SNAP_SUFFIX="rubriksnap"
# Pure - Target IRIS volume, the name of the target Volume mounted on the Proxy VM
TARGET_VOL="proxy_iris_vol"

# Mount point of the IRIS DB instance
MOUNT_POINT="/prd01"
# The /dev/<lv_name> that will be mounted to the mount point
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

# Number of days of log files to keep, older logs will be deleted
LOG_RETENTION_DAYS=60

# Current date time & location of the logfile
LAUNCHTIME=`date +%Y-%m-%d_%H%M`
LOGDIR="${SNAPDIR}/logs"
LOGFILE="${LOGDIR}/puresnaplog-${SOURCE_VOLUME}-${LAUNCHTIME}.log"
mkdir -p "${LOGDIR}"
touch $LOGFILE

# Delete log files older than the retention period
DELETED_LOGS=$(find "${LOGDIR}" -name "puresnaplog-*.log" -type f -mtime +${LOG_RETENTION_DAYS} -print -delete 2>/dev/null)
if [[ -n "$DELETED_LOGS" ]]; then
  echo "Cleaned up log files older than ${LOG_RETENTION_DAYS} days:"
  echo "$DELETED_LOGS"
  echo ""
fi

### VARIABLES - END ###

exit_failed() {
    # SUBJECT="AUTOMATED EMAIL: $(hostname): Epic IRIS ODB Pure Snap Script Failed"
    # EMAILMSG="The Pure Snap and Copy script failed.  Please review the log output"
    # EMAILLOG=`cat ${LOGFILE}`
    # EMAILBODY=${EMAILMSG}${EMAILLOG}
    #FN_email_log ${ADMINEMAILS} ${SUBJECT} ${EMAILBODY}
    rm $REFRESH_LOCK_FILE
    # exit 1
}

echo "Starting Pure IRIS ODB snap refresh script on $(hostname)"
echo "Current date is: $(date)"
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
  EPIC_AUTOTHAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1)
  # Comment out the JFS2 pieces if on RHEL
  # JFS_FREEZE_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_FREEZE_CMD} 2>&1)
  # JFS_AUTOTHAW_RESULT=$(/usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_AUTOTHAW_CMD} 2>&1)
fi

# Check the shell that the script is currently running in
CURRENT_SHELL=$(ps -p $$ -o args=)
echo "Currently running shell: ${CURRENT_SHELL}"

# Un-mount the mount point. This will also ensure that if the script fails to
# complete a refresh and re-mount, then if a backup runs it will fail since no
# files will be found.

echo "Unmounting: ${MOUNT_POINT}"
umount "${MOUNT_POINT}"

echo ""
echo "Starting Pure snap and copy process."
echo ""

echo "Getting volume information for: ${SOURCE_VOLUME}"
echo "Running Pure CLI: purevol list ${SOURCE_VOLUME} --notitle"
echo ""

VOLOUTPUT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol list ${SOURCE_VOLUME} --notitle")

if [[ -z "${VOLOUTPUT}" ]]; then
  echo "Volume not found or invalid: ${SOURCE_VOLUME}, exiting..."
  exit_failed
fi

echo "Found volume: ${SOURCE_VOLUME}"
echo ${VOLOUTPUT}
echo ""

echo "Checking for existing volume snaps to destroy."
echo "Running Pure CLI: purevol list ${SOURCE_VOLUME} --snap --notitle"
echo ""
VOLSNAPLIST=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol list ${SOURCE_VOLUME} --snap --notitle")
RUBRIKSNAPS=$(echo "$VOLSNAPLIST" | grep "$SOURCE_SNAP_SUFFIX")

if [[ -z "$RUBRIKSNAPS" ]]; then
  echo "No volume snapshots found matching ${SOURCE_SNAP_SUFFIX}."
  echo ""
else
  echo "Found the following volume snapshot(s) with suffix: ${SOURCE_SNAP_SUFFIX}"
  echo ${RUBRIKSNAPS}
  echo ""
  IFS=$'\n'
  for SNAP in $RUBRIKSNAPS; do
    SNAPNAME=$(echo "$SNAP" | awk '{print $1}')
    echo "Running Pure CLI: purevol destroy ${SNAPNAME}"
    VOLSNAPDESTROYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol destroy ${SNAPNAME}" 2>&1)
    if ! echo "$VOLSNAPDESTROYRESULT" | grep -q "Name"; then
      echo "Failed destroying volume snapshot: ${SNAPNAME}"
    else
      echo "Successfully destroyed volume snapshot, SafeMode will handle eradication"
      echo ${VOLSNAPDESTROYRESULT}
      echo ""
    fi
  done
  IFS=$' \t\n'  # Restore IFS to its default value
fi

echo "Creating volume snapshot of: ${SOURCE_VOLUME}"
CURRENT_DATE=$(date +%Y-%m-%d)
VOL_SNAP_SUFFIX="${SOURCE_SNAP_SUFFIX}-${CURRENT_DATE}"
echo "Volume snapshot suffix will be: ${VOL_SNAP_SUFFIX}"
echo ""

echo "Running Pure CLI: purevol snap --suffix ${VOL_SNAP_SUFFIX} ${SOURCE_VOLUME}"
VOLSNAPRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol snap --suffix ${VOL_SNAP_SUFFIX} ${SOURCE_VOLUME}" 2>&1)

if ! echo "$VOLSNAPRESULT" | grep -q "Created"; then
  echo "Failed creating volume snapshot: ${VOLSNAPRESULT}, exiting..."
  exit_failed
fi

echo ${VOLSNAPRESULT}
echo ""
sleep 3

if [ "$EXECUTE_EPIC" = "true" ]; then
  echo "Sending out commands to thaw IRIS ODB"
  # JFS2_THAW_RESULT=$(/usr/bin/ssh ${EPIC_PUBKEY_PATH} ${EPIC_ID}@${EPIC_SERVER} ${JFS2_THAW_CMD} 2>&1)
  EPIC_THAW_RESULT=$(/usr/bin/ssh ${EPIC_PUBKEY_PATH} ${EPIC_ID}@${EPIC_SERVER} ${EPIC_THAW_CMD} 2>&1)
fi

echo "Copying source volume snapshot to target volume"
echo ""
echo "Source volume: ${SOURCE_VOLUME}"
echo "Target volume: ${TARGET_VOL}"
echo ""

echo "Running Pure CLI: purevol copy --overwrite ${SOURCE_VOLUME}.${VOL_SNAP_SUFFIX} ${TARGET_VOL}"
COPYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol copy --overwrite ${SOURCE_VOLUME}.${VOL_SNAP_SUFFIX} ${TARGET_VOL}" 2>&1)
if ! echo "$COPYRESULT" | grep -q "Created"; then
  echo "Failed copy volume: ${COPYRESULT}, exiting..."
  exit_failed
fi
echo "$COPYRESULT"
echo ""

echo "Mounting: ${DEV_LV} to: ${MOUNT_POINT}"
# mount -o cio ${DEV_LV} ${MOUNT_POINT}
mount ${DEV_LV} ${MOUNT_POINT}
if mount | grep "$MOUNT_POINT" >/dev/null 2>&1; then
  echo "Verified: ${MOUNT_POINT} is mounted successfully."
else
  echo "ERROR: ${MOUNT_POINT} does not appear mounted, exiting..."
  exit_failed
fi
