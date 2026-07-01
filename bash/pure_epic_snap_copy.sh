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

# Current date time & location of the logfile
LAUNCHTIME=`date +%Y-%m-%d_%H%M`
LOGFILE="${SNAPDIR}/logs/puresnaplog-${LAUNCHTIME}.log"
touch $LOGFILE

# Lock file to check if the script is already running
REFRESH_LOCK_FILE="${SNAPDIR}/puresnaplockfile"

# Pure array hostname and username
PURE_ARRAY="sjc-rcf-pure04.stor.rubrik.com"
PURE_USER="perf-admin"

# Pure - Name of the Protection Group that the IRIS volumes belong to
SOURCE_PG_GROUP="Epic-PGPROD"
# Pure - This suffix will be appended to the PG Snap along with YYYY.MM.DD
#  <SOURCE_PG_GROUP>.<SOURCE_SNAP_SUFFIX>-YYYY-MM-DD
SOURCE_SNAP_SUFFIX="rubriksnap"
# Pure - Source IRIS volumes - The naming prefix, with a suffix of "##"
SOURCE_VOL_PREFIX="RNO-Stor-Tier1-EpicODB-PRD/RNO_Stor_Tier1_EpicODB_PRD_PRD1_"
# Pure - Target IRIS volumes - The naming prefix, with a suffix of "##"
TARGET_VOL_PREFIX="RNO-Stor-Tier1-EpicODB-PRD-BAKPRX/RNO-Stor-Tier1-EpicODB-PRD-BAKPRX-"

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

# Initialize the mount point arrays differently based on shell
if [[ "$CURRENT_SHELL" == *ksh* ]]; then
    echo "Defining mount point arrays for KornShell..."
    IFS=',' set -A MOUNT_POINTS_ARRAY $MOUNT_POINTS
    IFS=',' set -A DEV_LV_ARRAY $DEV_LV
fi

# Comment this out if using ksh
if [[ "$CURRENT_SHELL" != *ksh* ]]; then
    echo "Defining mount point arrays for Bash..."
    IFS=','
    MOUNT_POINTS_ARRAY=($MOUNT_POINTS)
    DEV_LV_ARRAY=($DEV_LV)
fi
echo ""

IFS=$' \t\n'  # Restore IFS to its default value

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
echo "Starting Pure snap and copy process."
echo ""

echo "Getting volume information for PG: ${SOURCE_PG_GROUP}"
echo "Running Pure CLI: purepgroup list ${SOURCE_PG_GROUP} --nvp"
echo ""

PGOUTPUT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup list ${SOURCE_PG_GROUP} --nvp")

if [[ -z "${PGOUTPUT}" ]]; then
  echo "PG invalid or did not find any LUNs for PG: ${SOURCE_PG_GROUP}, exiting..."
  exit_failed
fi

PGVOLUMES=$(echo "$PGOUTPUT" | sed -n 's/.*Volumes=//p')
echo "$PGVOLUMES" > "${SNAPDIR}/volumes.txt"
echo "Found volumes for PG: ${SOURCE_PG_GROUP}"
echo ${PGVOLUMES}
echo ""

echo "Checking for existing Rubrik PG snaps to destroy."
echo "Running Pure CLI: purepgroup list ${SOURCE_PG_GROUP} --snap --notitle"
echo ""
PGSNAPLIST=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup list ${SOURCE_PG_GROUP} --snap --notitle")
RUBRIKSNAPS=$(echo "$PGSNAPLIST" | grep "$SOURCE_SNAP_SUFFIX")

if [[ -z "$RUBRIKSNAPS" ]]; then
  echo "No PG snapshots found matching ${SOURCE_SNAP_SUFFIX}."
  echo ""
else
  echo "Found the following PG snapshot(s) with Rubrik suffix: ${SOURCE_SNAP_SUFFIX}"
  echo ${RUBRIKSNAPS}
  echo ""
  IFS=$'\n'
  for SNAP in $RUBRIKSNAPS; do
    SNAPNAME=$(echo "$SNAP" | awk '{print $1}')
    echo "Running Pure CLI: purepgroup destroy ${SNAPNAME}"
    PGSNAPDESTROYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup destroy ${SNAPNAME}" 2>&1)
    if ! echo "$PGSNAPDESTROYRESULT" | grep -q "Name"; then
      echo "Failed destroying PG snapshot: ${SNAPNAME}"
    else
      echo "Successfully destroyed PG snapshot, SafeMode will handle eradication"
      echo ${PGSNAPDESTROYRESULT}
      echo ""
    fi
  done
  IFS=$' \t\n'  # Restore IFS to its default value
fi

echo "Creating PG snapshot of PG: ${SOURCE_PG_GROUP}"
# Get the current date and format the suffix for the new PG snapshot
CURRENT_DATE=$(date +%Y-%m-%d)
PG_SNAP_SUFFIX="${SOURCE_SNAP_SUFFIX}-${CURRENT_DATE}"
echo "PG snapshot suffix will be: ${PG_SNAP_SUFFIX}"
echo ""

echo "Running Pure CLI: purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}"
PGSNAPRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purepgroup snap --suffix ${PG_SNAP_SUFFIX} ${SOURCE_PG_GROUP}" 2>&1)

if ! echo "$PGSNAPRESULT" | grep -q "Created"; then
  echo "Failed creating PG snapshot: ${PGSNAPRESULT}, exiting..."
  exit_failed
fi

echo ${PGSNAPRESULT}
echo ""
sleep 3

if [ "$EXECUTE_EPIC" = "true" ]; then
  echo "Sending out commands to thaw IRIS ODB"
  # JFS2_THAW_RESULT=$(/usr/bin/ssh ${EPIC_PUBKEY_PATH} ${EPIC_ID}@${EPIC_SERVER} ${JFS2_THAW_CMD} 2>&1)
  EPIC_THAW_RESULT=$(/usr/bin/ssh ${EPIC_PUBKEY_PATH} ${EPIC_ID}@${EPIC_SERVER} ${EPIC_THAW_CMD} 2>&1)
fi

echo "Copying source volumes to target volumes"
echo ""
echo "Source volumes: ${PGVOLUMES}"
echo "Source volume prefix: ${SOURCE_VOL_PREFIX}"
echo "Target volume prefix: ${TARGET_VOL_PREFIX}"
echo "For each source volume, the source prefix will be replaced with target prefix"
echo ""

IFS=','
for SOURCE_VOL in $PGVOLUMES; do
  echo ${SOURCE_VOL}
  TARGET_VOL=$(echo "$SOURCE_VOL" | sed "s|^$SOURCE_VOL_PREFIX|$TARGET_VOL_PREFIX|")
  # TARGET_VOL=$(echo "$SOURCE_VOL" | sed "s/^$SOURCE_VOL_PREFIX/$TARGET_VOL_PREFIX/")
  echo "Copying source volume: $SOURCE_VOL to target volume: $TARGET_VOL"
  echo "Running Pure CLI: purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force"
  COPYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol copy --overwrite ${SOURCE_PG_GROUP}.${PG_SNAP_SUFFIX}.${SOURCE_VOL} ${TARGET_VOL} --force" 2>&1)
  if ! echo "$COPYRESULT" | grep -q "Created"; then
    echo "Failed copy volume: ${COPYRESULT}, exiting..."
    exit_failed
  fi
  echo "$COPYRESULT"
  echo ""
done
IFS=$' \t\n'  # Restore IFS to its default value

# Print the arrays to verify
echo "Mount Base: $MOUNT_BASE"
echo "Mount Points Array: ${MOUNT_POINTS}"
echo "Device Logical Volumes Array: ${DEV_LV}"

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
