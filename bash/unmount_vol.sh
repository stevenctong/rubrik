#!/bin/bash
#
# Author: Steven Tong (Rubrik)
# Date Updated: 7/12/26
#
# Description:
# Unmounts a specified mount point. Pass the path as an argument or define
# it as the default variable below.
#
# Usage:
#   ./unmount_vol.sh /mnt/dctst    # pass mount point as argument
#   ./unmount_vol.sh               # use default MOUNT_POINT variable

### VARIABLES - BEGIN ###

MOUNT_POINT="/mnt/dctst"

### VARIABLES - END ###

# Use argument if provided, otherwise use default
if [[ -n "$1" ]]; then
  MOUNT_POINT="$1"
fi

if ! mount | grep -q "$MOUNT_POINT"; then
  echo "${MOUNT_POINT} is not currently mounted."
  exit 0
fi

echo "Unmounting: ${MOUNT_POINT}"
umount "${MOUNT_POINT}"

if mount | grep -q "$MOUNT_POINT"; then
  echo "ERROR: ${MOUNT_POINT} is still mounted."
  exit 1
fi

echo "Successfully unmounted: ${MOUNT_POINT}"
exit 0
