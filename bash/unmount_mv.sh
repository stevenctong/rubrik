#!/bin/bash
# Requires 'curl' and 'jq'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 12/23/20

# This script will Unmount all Managed Volumes with the provided name

# For authentication, use either an API token or base64 encoded username:password

### RUBRIK VARIABLES - BEGIN ###
# Configure an API token for authentication
TOKEN=''
# Configure a username:password for authenciation
# The username:password must be encoded as a base64 string.
# Use 'echo -n "admin:GoRubrik123" | base64' to generate with most Linux distros
USER_PASS=''
# Hostname or IP address of the Rubrik cluster
RUBRIK=''
# Script execution time
LAUNCHTIME=`date +%Y-%m-%d_%H%M%S`
### RUBRIK VARIABLES - END ###

### HELP - BEGIN ###
help()
{
  # Display Help
  echo "This script will Unmount all Managed Volumes with the provided name."
  echo
  echo "Syntax: unmount_mv.sh -n <MV name> -[d|h|m|q|s|t]"
  echo "Example: unmount_mv.sh -n 'slamv-oracle' -q 'y'"
  echo ""
  echo "Options:"
  echo "h :  Print help."
  echo "n :  Managed Volume name (required)."
  echo "q :  Quiet mode, set to '1' or 'all'."
  echo "     If '1' then it will only proceed if a single Live Mount is found for the MV."
  echo "     If 'all' then it will proceed no matter the number of Live Mounts found for the MV."
  echo ""
}
### HELP - END ###

echo "### Starting script unmount_mv.sh ###"
echo "Using shell: $SHELL"
echo "Script time: $LAUNCHTIME"
echo ""

### Check to ensure the json utility jq is installed
command -v jq >/dev/null 2>&1 || { echo >&2 "Script requires the utility jq. Aborting."; exit 1; }

# If an API token is provided, use that. Otherwise, use username password
if [ "$TOKEN" != '' ]
then
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
else
  AUTH_HEADER='Authorization:basic '
  AUTH_HEADER+=$USER_PASS
fi

# Define headers and base URL for curl REST API calls
TYPE_HEADER='Content-Type: application/json'
BASE_URL='https://'$RUBRIK'/api/'

# Get script arguments
while getopts "hd:m:n:q:s:t:" flag
do
  case $flag in
    h) # Display help
      help
      exit;;
    d) # Snapshot date to mount (UTC) (optional)
      SNAPSHOT_DATE=${OPTARG};;
    m) # Mount path prefix (optional)
      MOUNT_PATH=${OPTARG};;
    n) # Managed Volume name (required)
      MV_NAME=${OPTARG};;
    q) # Quiet mode, set to 'y' (optional)
      QUIET=${OPTARG};;
    s) # Subnet to use (optional)
      SUBNET=${OPTARG};;
    t) # Target host (optional)
      TARGET_HOST=${OPTARG};;
    \?) # Invalid option
      echo "ERROR: Invalid option, exiting..."
      exit;;
  esac
done

# If no arguments are provided, display help and exit
if [ $# -eq 0 ]; then
  help
  exit 1
fi

# If no MV name is provided, exit script
if [ "$MV_NAME" == '' ]; then
  echo "ERROR: No MV name provided, use '-n <MV_name>, exiting...'"
  exit 1
fi

MOUNTED_MVS=$(curl -k1s -X GET -H "$AUTH_HEADER" -H "$CONTENT_HEADER" "$BASE_URL"'internal/managed_volume/snapshot/export?source_managed_volume_name='"$MV_NAME")

# If no Live Mounted MVs was found by that name, exit script
if [ $(echo $MOUNTED_MVS | jq -r '.total') -eq 0 ]; then
  echo "ERROR: No Live Mounted MVs found by name: ${MV_NAME}, exiting..."
  exit 1
fi

# REST API calls returns all partial name matches
# Loop through results to find an exact match and grab the Live Mount(s) that match the name
MOUNTED_IDS=()
MOUNTED_SNAPSHOT_DATES=()
MOUNTED_TIMES=()

MOUNTED_STRING=$(echo $MOUNTED_MVS | jq -c '.data[]')
while read -r line
do
  MOUNTED_NAME=$(echo $line | jq -r '.sourceManagedVolumeName')
  if [ "$MOUNTED_NAME" == $MV_NAME ]
  then
    MOUNTED_IDS+=($(echo $line | jq -r '.id'))
    MOUNTED_SNAPSHOT_DATES+=($(echo $line | jq -r '.snapshotDate'))
    MOUNTED_TIMES+=($(echo $line | jq -r '.exportedDate'))
  fi
done <<< "$MOUNTED_STRING"

MOUNTED_NUM=${#MOUNTED_IDS[@]}
if [ $MOUNTED_NUM -eq 0 ]; then
  echo "ERROR: No Live Mounted MVs found by name: ${MV_NAME}, exiting..."
  exit 1
fi

echo "${MOUNTED_NUM} Live Mounts found for MV: ${MV_NAME}"

i=0
while [ $i -lt $MOUNTED_NUM ]
do
  echo "Snapshot time: ${MOUNTED_SNAPSHOT_DATES[$i]}; mount time: ${MOUNTED_TIMES[$i]}  (UTC)"
  ((i++))
done

if [ "$QUIET" == '1' ]
then
  if [ $MOUNTED_NUM -gt 1 ]; then
    echo ""
    echo "ERROR: More than 1 Live Mount found in Quiet mode = '1', exiting..."
    exit 1
  fi
elif [ "$QUIET" != 'all' ]
then
  # Checks that the user wants to proceed by typing 'y'. Otherwise, exits script
  echo -e -n "\nType 'y' to proceed with Unmounting:  "
  read USERPROCEED

  if [ "$USERPROCEED" != 'y' ]
  then
    echo "Exiting script"; exit 2
  fi
fi

i=0
while [ $i -lt $MOUNTED_NUM ]
do
  echo ""
  echo "Deleting snapshot time: ${MOUNTED_SNAPSHOT_DATES[$i]}; mount time: ${MOUNTED_TIMES[$i]}  (UTC)"
  echo "Snapshot ID: ${MOUNTED_IDS[$i]}"
  curl -k1si -X DELETE -H "$AUTH_HEADER" -H "$CONTENT_HEADER" "$BASE_URL"'internal/managed_volume/snapshot/export/'"${MOUNTED_IDS[$i]}"
  ((i++))
done
