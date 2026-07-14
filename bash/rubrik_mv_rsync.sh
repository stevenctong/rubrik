#!/bin/bash
#
# Author: Steven Tong (Rubrik)
# Updated: 7/13/26
#
# Description:
# Wrapper script that opens a Rubrik Managed Volume (MV), copies new files
# from a source directory to a target directory using rsync, and closes the MV.
#
# Only files that do not already exist on the target are copied (rsync
# --ignore-existing). The rsync --stats flag provides a summary of files
# transferred and total size.
#
# If the MV open fails, the script exits without copying or closing.
# If the rsync fails, the script still attempts to close the MV before exiting.
#
# Usage:
#   ./rubrik_mv_rsync.sh
#
# The MV open/close commands are configurable -- set MV_OPEN_CMD and
# MV_CLOSE_CMD to the full command including path and arguments.
# Use --no-log on the MV script to avoid double logging.
#
# Example:
#   MV_OPEN_CMD="./rubrik_mv_open_close.sh open --no-log"
#   MV_CLOSE_CMD="./rubrik_mv_open_close.sh close --no-log"

### VARIABLES - BEGIN ###

# Command to open the MV (full path and arguments)
MV_OPEN_CMD="./rubrik_mv_open_close.sh open --no-log"

# Command to close the MV (full path and arguments)
MV_CLOSE_CMD="./rubrik_mv_open_close.sh close --no-log"

# Source directory to copy new files from
SOURCE_DIR=""

# Target directory on the MV to copy new files to
TARGET_DIR=""

# Sync mode: "mirror" or "new_only"
#   mirror   - target becomes an exact copy of source (adds new files, deletes
#              files not on source, updates modified files)
#   new_only - only copy files that do not exist on the target (no deletes,
#              no overwrites)
SYNC_MODE="mirror"

### VARIABLES - END ###

### Derived variables - BEGIN ###

SCRIPTDIR="."
LAUNCHTIME=$(date +%Y-%m-%d_%H%M%S)
LOG_RETENTION_DAYS=60
LOGDIR="${SCRIPTDIR}/logs"
LOGFILE="${LOGDIR}/mv_rsync-${LAUNCHTIME}.log"
mkdir -p "${LOGDIR}"
touch "${LOGFILE}"

DELETED_LOGS=$(find "${LOGDIR}" -name "mv_rsync-*.log" -type f -mtime +${LOG_RETENTION_DAYS} -print -delete 2>/dev/null)
if [[ -n "$DELETED_LOGS" ]]; then
  echo "Cleaned up log files older than ${LOG_RETENTION_DAYS} days:"
  echo "$DELETED_LOGS"
  echo ""
fi

### Derived variables - END ###

# Redirect all output to both stdout and the log file
exec &> >(tee -a "${LOGFILE}")

echo "Starting rubrik_mv_rsync.sh on $(hostname)"
echo "Current date: $(date)"
echo "Log file: ${LOGFILE}"
echo ""

# Validate required variables
if ! command -v rsync &>/dev/null; then
  echo "ERROR: rsync is not installed, exiting..."
  exit 1
fi

if [[ -z "$MV_OPEN_CMD" ]]; then
  echo "ERROR: MV_OPEN_CMD is not set, exiting..."
  exit 1
fi

if [[ -z "$MV_CLOSE_CMD" ]]; then
  echo "ERROR: MV_CLOSE_CMD is not set, exiting..."
  exit 1
fi

if [[ -z "$SOURCE_DIR" ]]; then
  echo "ERROR: SOURCE_DIR is not set, exiting..."
  exit 1
fi

if [[ -z "$TARGET_DIR" ]]; then
  echo "ERROR: TARGET_DIR is not set, exiting..."
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "ERROR: SOURCE_DIR does not exist: ${SOURCE_DIR}, exiting..."
  exit 1
fi

if [[ "$SYNC_MODE" != "mirror" && "$SYNC_MODE" != "new_only" ]]; then
  echo "ERROR: SYNC_MODE must be 'mirror' or 'new_only', got: ${SYNC_MODE}, exiting..."
  exit 1
fi

echo "Source directory: ${SOURCE_DIR}"
echo "Target directory: ${TARGET_DIR}"
echo "Sync mode: ${SYNC_MODE}"
echo "MV open command: ${MV_OPEN_CMD}"
echo "MV close command: ${MV_CLOSE_CMD}"
echo ""

# Step 1: Open the MV
echo "--- Opening Managed Volume ---"
echo ""
$MV_OPEN_CMD
OPEN_RC=$?

if [[ $OPEN_RC -ne 0 ]]; then
  echo ""
  echo "ERROR: MV open command failed with exit code ${OPEN_RC}, exiting..."
  exit 1
fi

echo ""
echo "MV opened successfully"
echo ""

# Step 2: Rsync new files from source to target
echo "--- Rsync: copying new files ---"
echo ""

if [[ "$SYNC_MODE" == "mirror" ]]; then
  echo "Mode: mirror (target will be an exact copy of source)"
  echo ""
  rsync -av --delete --stats "${SOURCE_DIR}/" "${TARGET_DIR}/"
else
  echo "Mode: new_only (copying files not on target, no deletes)"
  echo ""
  rsync -av --ignore-existing --stats "${SOURCE_DIR}/" "${TARGET_DIR}/"
fi
RSYNC_RC=$?

echo ""

if [[ $RSYNC_RC -ne 0 ]]; then
  echo "ERROR: rsync failed with exit code ${RSYNC_RC}"
  echo "Attempting to close the MV before exiting..."
  echo ""

  # Step 3 (on failure): Close the MV
  echo "--- Closing Managed Volume ---"
  echo ""
  $MV_CLOSE_CMD
  CLOSE_RC=$?

  if [[ $CLOSE_RC -ne 0 ]]; then
    echo ""
    echo "ERROR: MV close command also failed with exit code ${CLOSE_RC}"
  else
    echo ""
    echo "MV closed successfully"
  fi

  echo ""
  echo "Script failed due to rsync error"
  exit 1
fi

echo "Rsync completed successfully"
echo ""

# Step 3 (on success): Close the MV
echo "--- Closing Managed Volume ---"
echo ""
$MV_CLOSE_CMD
CLOSE_RC=$?

if [[ $CLOSE_RC -ne 0 ]]; then
  echo ""
  echo "ERROR: MV close command failed with exit code ${CLOSE_RC}, exiting..."
  exit 1
fi

echo ""
echo "MV closed successfully"
echo ""
echo "Script completed successfully"
exit 0
