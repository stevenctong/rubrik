#!/bin/bash
#
# Author: Steven Tong (Rubrik)
# Date Updated: 7/10/26
#
# Description:
# Refreshes Epic IRIS ODB volume(s) on a Proxy VM by creating Pure Storage
# snapshots of the source volume(s) and copying them to the target volume(s).
# Supports multiple volumes for VG/LVM setups with a 1:1 source-to-target mapping.
# The script unmounts the target, destroys any previous snapshots with the
# configured suffix, creates new snapshots, optionally freezes/thaws the Epic
# IRIS instance, copies the snapshots to the target volumes, and re-mounts.
#
# Supports multiple Epic instances by passing an optional config file as an
# argument to override the default variables (see .conf example file).
#
# Usage:
#   ./pure_epic_snap_copy_individual.sh                        # use default variables
#   ./pure_epic_snap_copy_individual.sh /path/to/instance.conf # use config overrides
#
# Script should be in a location that contains: "/rubrik/scripts" in the path
# Script location can be defined at: ${SNAPDIR}
# Create a sub-directory "/logs" under ${SNAPDIR} for logs
#
# Setup: Configuring the Proxy VM Target Volume(s) (TARGET_VOLUME)
# The first snapshot copy will auto-create the target volume(s) on the Pure array.
# After the volumes are created, you still need to map and attach them:
# 1. Run the script once to create the snapshot and copy to target volume(s)
#    (the copy command auto-creates the target volumes on the Pure array)
# 2. Map the new volume(s) to the host or host group of the ESXi cluster that the
#    Proxy VM resides on
# 3. Attach the new volume(s) as Raw Device Mappings (RDM) to the Proxy VM
# 4. The name(s) of these volumes on the Pure array go in the "TARGET_VOLUME" variable
# 5. For first-time setup on the Proxy VM, follow the Linux or AIX steps below
#    to discover, activate, and mount the LUN
# On subsequent runs, the target volumes already exist and are overwritten in place.
# Repeat steps 2-3 for each target volume if the VG has multiple PVs.
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
# 3. "blkid </dev/sdb>>" - check the physical disk signature to confirm LVM
# 4. "pvresize /dev/sdaf" - resize the PV to what it should be
# 5. "pvs /dev/sdaf" -  get the name of the volume group on the PV
# 6. "vgchange -an epicdctstvg" - vary off the volume group
# 7. "vgchange -ay epicdctstvg" - vary on the volume group
# 8. "ls -l /dev/mapper" - find the device mapper paths for LVs
# 9. "mount /dev/mapper/epicdctstvg-dctstlv001 /mnt/dctst" - mount the LV to a mount point

### VARIABLES - BEGIN ###

# Optional: pass a config file as an argument to override the default variables below
# Usage: ./pure_epic_snap_copy_individual.sh [config_file]
# Example: ./pure_epic_snap_copy_individual.sh /rubrik/scripts/dctst.conf

### Instance-specific variables (can be overridden by config file) - BEGIN ###

# Name of the Epic instance (used in log filenames)
INSTANCE_NAME="epic_instance"

# Whether or not to execute the Epic IRIS freeze / thaw for testing
EXECUTE_EPIC="false"

# Pure array hostname and username
PURE_ARRAY="sjc-rcf-pure04.stor.rubrik.com"
PURE_USER="perf-admin"

# Pure - source IRIS ODB volume(s) on the Pure array
# For multiple volumes (e.g. VG with multiple PVs), use comma-separated values
# Each source volume maps 1:1 to the corresponding target volume by position
SOURCE_VOLUME="iris_sourcevol"
# SOURCE_VOLUME="iris_sourcevol1,iris_sourcevol2,iris_sourcevol3"

# Pure - This suffix will be appended to the Volume Snap along with YYYY-MM-DD-HHMM
#  <SOURCE_VOLUME>.<SOURCE_SNAP_SUFFIX>-YYYY-MM-DD-HHMM
SOURCE_SNAP_SUFFIX="rubriksnap"

# Pure - target IRIS volume(s), the name of the target volume(s) on the Proxy VM that will be refreshed
# Must have the same number of entries as SOURCE_VOLUME (1:1 mapping)
TARGET_VOLUME="proxy_iris_vol"
# TARGET_VOLUME="proxy_target1,proxy_target2,proxy_target3"

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

### Instance-specific variables (can be overridden by config file) - END ###

# If a config file is passed as an argument, source it to override the defaults above
if [[ -n "$1" ]]; then
  if [[ ! -f "$1" ]]; then
    echo "Config file not found: $1, exiting..."
    exit 1
  fi
  echo "Sourcing config file: $1"
  source "$1"
fi

# Split comma-separated volume lists into arrays and validate 1:1 mapping
IFS=',' read -ra SOURCE_VOLUMES <<< "$SOURCE_VOLUME"
IFS=',' read -ra TARGET_VOLUMES <<< "$TARGET_VOLUME"

if [[ ${#SOURCE_VOLUMES[@]} -ne ${#TARGET_VOLUMES[@]} ]]; then
  echo "ERROR: SOURCE_VOLUME has ${#SOURCE_VOLUMES[@]} entries but TARGET_VOLUME has ${#TARGET_VOLUMES[@]} entries."
  echo "Each source volume must map 1:1 to a target volume."
  exit 1
fi

### Derived variables (not overridden by config file) - BEGIN ###

# Directory where script files will be located and run from
SNAPDIR="."

# Lock file to check if the script is already running
REFRESH_LOCK_FILE="${SNAPDIR}/puresnaplockfile"

# JFS2_FREEZE_CMD="chfs -a freeze=60 /epic/sup01 ; chfs -a freeze=60 /epic/sup02 ; chfs -a freeze=60 /epic/sup03 ; chfs -a freeze=60 /epic/sup04"
# JFS2_THAW_CMD="chfs -a freeze=off /epic/sup01 ; chfs -a freeze=off /epic/sup02 ; chfs -a freeze=off /epic/sup03 ; chfs -a freeze=off /epic/sup04"
# JFS2_AUTOTHAW_CMD="nohup sh -c '(sleep 1m && ${JFS2_THAW_CMD}) > /dev/null 2>&1 &'"

# Number of days of log files to keep, older logs will be deleted
LOG_RETENTION_DAYS=60

# Current date time & location of the logfile
LAUNCHTIME=$(date +%Y-%m-%d_%H%M)
LOGDIR="${SNAPDIR}/logs"
LOGFILE="${LOGDIR}/puresnaplog-${INSTANCE_NAME}-${LAUNCHTIME}.log"
mkdir -p "${LOGDIR}"
touch $LOGFILE

# Delete log files older than the retention period
DELETED_LOGS=$(find "${LOGDIR}" -name "puresnaplog-*.log" -type f -mtime +${LOG_RETENTION_DAYS} -print -delete 2>/dev/null)
if [[ -n "$DELETED_LOGS" ]]; then
  echo "Cleaned up log files older than ${LOG_RETENTION_DAYS} days:"
  echo "$DELETED_LOGS"
  echo ""
fi

### Derived variables (not overridden by config file) - END ###

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

# Redirect all output to both stdout and the log file
exec &> >(tee -a "${LOGFILE}")

echo "Starting Pure IRIS ODB snap refresh script on $(hostname)"
echo "Current date is: $(date)"
echo "Log file: ${LOGFILE}"
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
  /usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_FREEZE_CMD}
  /usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${EPIC_AUTOTHAW_CMD}
  # Comment out the JFS2 pieces if on RHEL
  # /usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_FREEZE_CMD}
  # /usr/bin/ssh ${EPIC_ID}@${EPIC_SERVER} ${JFS2_AUTOTHAW_CMD}
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
CURRENT_DATE=$(date +%Y-%m-%d-%H%M)
VOL_SNAP_SUFFIX="${SOURCE_SNAP_SUFFIX}-${CURRENT_DATE}"
echo "Volume snapshot suffix will be: ${VOL_SNAP_SUFFIX}"
echo "Processing ${#SOURCE_VOLUMES[@]} volume(s)"
echo ""

# Loop 1: Verify volumes, destroy old snapshots, and create new snapshots
for i in "${!SOURCE_VOLUMES[@]}"; do
  SRC_VOL="${SOURCE_VOLUMES[$i]}"
  TGT_VOL="${TARGET_VOLUMES[$i]}"

  echo "--- Volume $((i+1)) of ${#SOURCE_VOLUMES[@]}: ${SRC_VOL} -> ${TGT_VOL} ---"
  echo ""

  echo "Getting volume information for: ${SRC_VOL}"
  echo "Running Pure CLI: purevol list ${SRC_VOL} --notitle"
  echo ""

  VOLOUTPUT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol list ${SRC_VOL} --notitle")

  if [[ -z "${VOLOUTPUT}" ]]; then
    echo "Volume not found or invalid: ${SRC_VOL}, exiting..."
    exit_failed
  fi

  echo "Found volume: ${SRC_VOL}"
  echo ${VOLOUTPUT}
  echo ""

  echo "Checking for existing volume snaps to destroy."
  echo "Running Pure CLI: purevol list ${SRC_VOL} --snap --notitle"
  echo ""
  VOLSNAPLIST=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol list ${SRC_VOL} --snap --notitle")
  RUBRIKSNAPS=$(echo "$VOLSNAPLIST" | grep "$SOURCE_SNAP_SUFFIX")

  if [[ -z "$RUBRIKSNAPS" ]]; then
    echo "No volume snapshots found matching ${SOURCE_SNAP_SUFFIX}."
    echo ""
  else
    echo "Found the following volume snapshots with suffix: ${SOURCE_SNAP_SUFFIX}"
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
    IFS=$' \t\n'
  fi

  echo "Creating volume snapshot of: ${SRC_VOL}"
  echo "Running Pure CLI: purevol snap --suffix ${VOL_SNAP_SUFFIX} ${SRC_VOL}"
  VOLSNAPRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol snap --suffix ${VOL_SNAP_SUFFIX} ${SRC_VOL}" 2>&1)

  if ! echo "$VOLSNAPRESULT" | grep -q "Created"; then
    echo "Failed creating volume snapshot: ${VOLSNAPRESULT}, exiting..."
    exit_failed
  fi

  echo ${VOLSNAPRESULT}
  echo ""

done

sleep 3

if [ "$EXECUTE_EPIC" = "true" ]; then
  echo "Sending out commands to thaw IRIS ODB"
  # /usr/bin/ssh ${EPIC_PUBKEY_PATH} ${EPIC_ID}@${EPIC_SERVER} ${JFS2_THAW_CMD}
  /usr/bin/ssh ${EPIC_PUBKEY_PATH} ${EPIC_ID}@${EPIC_SERVER} ${EPIC_THAW_CMD}
fi

# Loop 2: Copy each snapshot to its corresponding target volume
echo "Copying source volume snapshots to target volumes"
echo ""

for i in "${!SOURCE_VOLUMES[@]}"; do
  SRC_VOL="${SOURCE_VOLUMES[$i]}"
  TGT_VOL="${TARGET_VOLUMES[$i]}"

  echo "--- Copy $((i+1)) of ${#SOURCE_VOLUMES[@]}: ${SRC_VOL}.${VOL_SNAP_SUFFIX} -> ${TGT_VOL} ---"
  echo ""

  echo "Running Pure CLI: purevol copy --overwrite ${SRC_VOL}.${VOL_SNAP_SUFFIX} ${TGT_VOL}"
  COPYRESULT=$(/usr/bin/ssh ${PURE_USER}@${PURE_ARRAY} "purevol copy --overwrite ${SRC_VOL}.${VOL_SNAP_SUFFIX} ${TGT_VOL}" 2>&1)
  if ! echo "$COPYRESULT" | grep -q "Created"; then
    echo "Failed copy volume: ${COPYRESULT}, exiting..."
    exit_failed
  fi
  echo "$COPYRESULT"
  echo ""

done

echo "Mounting: ${DEV_LV} to: ${MOUNT_POINT}"
# mount -o cio ${DEV_LV} ${MOUNT_POINT}
mount ${DEV_LV} ${MOUNT_POINT}
if mount | grep "$MOUNT_POINT" >/dev/null 2>&1; then
  echo "Verified: ${MOUNT_POINT} is mounted successfully."
else
  echo "ERROR: ${MOUNT_POINT} does not appear mounted, exiting..."
  exit_failed
fi

echo ""
echo "Script completed successfully."
rm $REFRESH_LOCK_FILE
exit 0
