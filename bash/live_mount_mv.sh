#!/bin/bash
# Requires 'curl' and 'jq'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 12/23/20

# This script will Live Mount a Managed Volume

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
# Set MONITOR to non-zero if you want the script to monitor progress until the backup has finished
MONITOR=0
# Script execution time
LAUNCHTIME=`date +%Y-%m-%d_%H%M%S`
### RUBRIK VARIABLES - END ###

### HELP - BEGIN ###
help()
{
  # Display Help
  echo "This script will Live Mount a Managed Volume."
  echo
  echo "Syntax: live_mount_mv.sh -n <MV name> -[d|h|m|q|s|t]"
  echo "Example: live_mount_mv.sh -n 'slamv-oracle' -q 'y'"
  echo "Example: live_mount_mv.sh -n 'slamv-oracle' -d '2021-12-01' -m '/mnt/ch' -t 'ora1.corp.com' -s '10.8.8.0/24'"
  echo ""
  echo "Options:"
  echo "d :  Snapshot date (UTC) to mount. Uses most recent snapshot if blank."
  echo "h :  Print help."
  echo "m :  Mount path prefix. Uses source mount paths if blank."
  echo "     A # starting from 0 will be automatically be appended up to the # of channels."
  echo "n :  Managed Volume name (required)."
  echo "q :  Quiet mode, set to 'y'."
  echo "s :  Subnet to use, required if VLANs are configured. Uses source subnet if blank."
  echo "t :  Target host. Uses source host if blank."
  echo ""
}
### HELP - END ###

echo "### Starting script live_mount_mv.sh ###"
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

# Get details of the Managed Volume
MV=$(curl -k1s -X GET -H "$AUTH_HEADER" -H "$CONTENT_HEADER" "$BASE_URL"'internal/managed_volume?primary_cluster_id=local&name='"$MV_NAME")

# If no MV was found by that name, exit script
if [ $(echo $MV | jq -r '.total') -eq 0 ]; then
  echo "ERROR: No MV found by name: ${MV_NAME}, exiting..."
  exit 1
fi

echo "Managed Volume name: $MV_NAME"

# Set variables based on the MV attributes
MV_ID=$(echo $MV | jq -r '.data[0].id')
MV_SUBNET=$(echo $MV | jq -r '.data[0].subnet')
MV_HOSTID=$(echo $MV | jq -r '.data[0].slaManagedVolumeDetails.hostDetails.hostId')
MV_HOSTNAME=$(echo $MV | jq -r '.data[0].slaManagedVolumeDetails.hostDetails.hostName')
MV_NUMCHANNELS=$(echo $MV | jq -r '.data[0].numChannels')
MV_MOUNTPATHS=$(echo $MV | jq -cr '.data[0].slaManagedVolumeDetails.channelHostMountPaths[]')

## Get target host info we want to live mount the MV to
TARGET_ID=''

# If no target host is provided, mount to the same MV source host
if [ "$TARGET_HOST" == '' ]
then
  TARGET_HOST=$MV_HOSTNAME
  echo "No target host provided - using MV source host"
  TARGET_ID=$MV_HOSTID
# Otherwise, if a target host is provided, make sure it's valid and get its ID
else
  HOSTS=$(curl -k1s -X GET -H "$AUTH_HEADER" -H "$CONTENT_HEADER" "$BASE_URL"'v1/host?operating_system_type=Linux&primary_cluster_id=local&name='"$TARGET_HOST")

  # If no target host is found, exit script
  if [ $(echo $HOSTS | jq -r '.total') -eq 0 ]; then
    echo "ERROR: No target host found by name: ${TARGET_HOST}, exiting..."
    exit 1
  fi

  # REST API calls returns all partial name matches
  # Loop through results to find an exact match and grab the target host ID
  HOSTS_STRING=$(echo $HOSTS | jq -c '.data[]')
  while read -r line
  do
    HOSTNAME=$(echo $line | jq -r '.name')
    if [ "$TARGET_HOST" == "$HOSTNAME" ]
    then
      TARGET_ID=$(echo $line | jq -r '.id')
    fi
  done <<< "$HOSTS_STRING"

  if [ "$TARGET_ID" == '' ]; then
    echo "ERROR: No target host found by name: ${TARGET_HOST}, exiting..."
    exit 1
  fi
fi

echo "Target host: $TARGET_HOST"

## Get mount path info we want to Live Mount the MV to
# If no mount path is provided, use the same source MV mount paths
if [ "$MOUNT_PATH" == '' ]
then
  echo "No mount path provided - using MV mount paths:"
  echo $MV_MOUNTPATHS

  # Creates a JSON array from the source mount paths
  MOUNT_ARRAY=$(jq -n --arg paths "$MV_MOUNTPATHS" '$paths | split("\n")')
# If a mount path prefix is provided then create a list of mount paths
# The mount paths will have a number appended starting from 0 up to the # of channels
else
  MV_MOUNTPATHS=()
  # Assuming that the array index starts at '0'
  i=0

  while [ $i -lt $MV_NUMCHANNELS ]
  do
    CUR_PATH="${MOUNT_PATH}${i}"
    MV_MOUNTPATHS+=($CUR_PATH)
    ((i++))
  done

  # Creates a JSON array of the mount paths
  MOUNT_ARRAY=$(jq -n '$ARGS.positional' --args "${MV_MOUNTPATHS[@]}")
fi

# Output the JSON array of mount paths to a raw string format
MOUNT_ARRAY=$(echo $MOUNT_ARRAY | jq -r '.[]')

# If no subnet was provided, check if the source MV has a subnet and use that if found
# Otherwise, do not configure the Live Mount with a subnet
# Create the JSON payload
if [ "$SUBNET" == '' ]
then
  if [ "$MV_SUBNET" == 'null' ]
  then
    JSON_BODY=$(jq -n --arg hostid "$TARGET_ID" --arg mount "$MOUNT_ARRAY" '{hostId: $hostid, hostMountPaths: $mount | split("\n") }')
  else
    JSON_BODY=$(jq -n --arg subnet "$MV_SUBNET" --arg hostid "$TARGET_ID" --arg mount "$MOUNT_ARRAY" '{subnet: $subnet, hostId: $hostid, hostMountPaths: $mount | split("\n") }')
  fi
# If a subnet was provided, creat the JSON payload with it
else
  JSON_BODY=$(jq -n --arg subnet "$SUBNET" --arg hostid "$TARGET_ID" --arg mount "$MOUNT_ARRAY" '{subnet: $subnet, hostId: $hostid, hostMountPaths: $mount | split("\n") }')
fi

## Gather available snapshots for the MV
SNAPSHOTS=$(curl -k1s -X GET -H "$AUTH_HEADER" -H "$CONTENT_HEADER" "$BASE_URL"'internal/managed_volume/'"$MV_ID"'/snapshot')

# If no snapshots are found, exit script
if [ $(echo $SNAPSHOTS | jq -r '.total') -eq 0 ]; then
  echo "ERROR: No snapshots found, exiting..."
  exit 1
fi

## Find all snapshots for the MV and select the one closest to the provided date or the latest
# Initiate an array to store the snapshot IDs and dates
# The oldest snapshot will be the first index in the array (array[1])
SNAPSHOTIDS=()
SNAPSHOTDATES=()

# Get the snapshots from the fileset data
SNAPSHOTINFO=$(echo $SNAPSHOTS | jq -c '.data[]')

# Loop through the snapshots and pull out the snapshot IDs and dates
while read -r line
do
  SNAPSHOTIDS+=($(echo $line | jq -r '.id'))
  SNAPSHOTDATES+=($(echo $line | jq -r '.date'))
done <<< "$SNAPSHOTINFO"

# If no snapshot date was provided, then use the latest snapshot
# The latest snapshot is the one last in the array
if [ "$SNAPSHOT_DATE" == '' ]
then
  echo "No snapshot date (UTC) provided - using the latest snapshot: ${SNAPSHOTDATES[${#SNAPSHOTDATES[@]} - 1]} UTC"
  SNAPSHOT_ID=${SNAPSHOTIDS[${#SNAPSHOTIDS[@]} - 1]}
# If a date was passed as an argument then find the closest snapshot to that date and use it
else
  # Calculate the epoch time of the passed in date
  INPUT_EPOCH=$(date -d $SNAPSHOT_DATE +"%s")

  # Holds the epoch time difference for comparisons
  EPOCH_DIFF=9999999

  # Assuming that the array index starts at '0'
  j=0
  while [ $j -lt ${#SNAPSHOTDATES[@]} ]
  do
    # Get the epoch of the current date to compare to
    J_EPOCH=$(date -d ${SNAPSHOTDATES[$j]} +"%s")

    # Calculate the difference between the passed in date and current date
    CURRENT_DIFF=$(($INPUT_EPOCH - $J_EPOCH))

    # Compare using the absolute value of the difference
    if [ $CURRENT_DIFF -gt 0 ]
    then
      # If the current difference is less than the comparison difference then this date is closer
      if [ "$CURRENT_DIFF" -lt "$EPOCH_DIFF" ]
      then
        USERSNAPSHOT=$j
        EPOCH_DIFF=$CURRENT_DIFF
      fi
    # Swap calculating the difference to compare using the absolute value
    else
      CURRENT_DIFF=$(($J_EPOCH - $INPUT_EPOCH))
      if [ $CURRENT_DIFF -lt $EPOCH_DIFF ]
      then
        USERSNAPSHOT=$j
        EPOCH_DIFF=$CURRENT_DIFF
      fi
    fi
    ((j++))
  done

  # $USERSNAPSHOT is the index of the closest snapshot to the provided time
  SNAPSHOT_ID=${SNAPSHOTIDS[$USERSNAPSHOT]}

  echo "Using snapshot nearest date $SNAPSHOT_DATE: ${SNAPSHOTDATES[$USERSNAPSHOT]} UTC"
fi

echo "JSON payload:"
echo $JSON_BODY | jq

# If not quiet mode then check if then prompt for the user to confirm to proceed
if [ "$QUIET" != 'y' ]
then
  # Checks that the user wants to proceed by typing 'y'. Otherwise, exits script
  echo -e -n "\nType 'y' to proceed:  "
  read USERPROCEED

  if [ "$USERPROCEED" != 'y' ]
  then
    echo "Exiting script"; exit 2
  fi
fi

# Execute REST API call to Live Mount the MV
RESULT=$(curl -k1s -X POST -H "$AUTH_HEADER" -H "$CONTENT_HEADER" -d "$JSON_BODY" "$BASE_URL"'internal/managed_volume/snapshot/'"$SNAPSHOT_ID"'/restore')

echo $RESULT

## Monitor the REST API call to completion
if [ $MONITOR -ne 0 ]
then
  if [ $(echo $RESULT | grep 'href' -c) -eq 0 ]
  then
    echo "ERROR: REST API call did not return a status URL, exiting..."
    exit 1
  fi

  # Reset $STATUS in case it contains other values
  STATUS=""

  # Pull out the URL that we use to query status
  HREF=$(echo $RESULT | sed -e 's/.*href\"\:\"\(.*\)\"\,.*/\1/')
  RUBRIKSTATUS=0

  while [ $RUBRIKSTATUS -eq 0 ]
  do
    sleep 15
    # Query the URL for the current status of the on demand backup
    STATUS=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' "$HREF" -k -1 -s)

    # Check if any of the end states are found, if so, $RUBRIKSTATUS changes and loop exits
    RUBRIKSTATUS=$(echo $STATUS | grep 'SUCCEED\|SUCCESS\|SUCCESSWITHWARNINGS\|FAIL\|CANCEL' -c)

    echo $STATUS
  done
fi
