#!/bin/bash
# Requires 'curl' and 'jq'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 12/10/20, updated: 10/24/21

# This script will restore a fileset to an alternate host (fileset export).
# A list of source and target directories must be provided.
# The script will list the available snapshots for the fileset so the user can select a point in time for restore.
# Once selected the script will kick off a restore job for each source-target directory pair.

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
# SOURCE - Fileset ID that you want to restore from
FILESETID='Fileset:::62155444-b52f-410b-b5d1-64e371787f5b'
# SOURCE - List of directories to restore, separated by a space in the array.
# All files and sub-directories under these directories will be selected for restore.
SOURCE_DIR=('/epic/prd01' '/epic/prd02' '/epic/prd03')
# TARGET -  List of directories to restore to, must have same number of directories as $SOURCE_DIR.
# All files and sub-directories from each source directory will be restored to the corresponding target directory.
TARGET_DIR=('/restore/prd01' '/restore/prd02' '/restore/prd03')
# TARGET - Host ID that you want to restore to.
# If $TARGET_HOSTID is blank,  the restore will be done to the same host it was backed up from
TARGET_HOSTID=''
# TARGET_HOSTID='Host:::37eaa1b3-df31-4c06-9ae5-18e0f9ce8769'
# Set MONITOR to non-zero if you want the script to monitor progress until the backup has finished
MONITOR=0
# Script execution time
LOGPATH= #SomePath
LAUNCHTIME=`date +%m%d%y_%H%M%S`
################################################################################

### Check to ensure the json utility jq is installed
echo $SHELL

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

# Checks if the number of restore directories to target directories is equal, exits on error
if [ ${#SOURCE_DIR[@]} != ${#TARGET_DIR[@]} ]
then
  echo "ERROR: Number of SOURCE_DIR is not equal to TARGET_DIR. ABORTING"
  exit 1
fi

# Check that the target host is valid if it is configured
if [ "$TARGET_HOSTID" != '' ]
then
  # Gets the hostname of the Target Host ID and exits if the host is not found
  TARGET_HOSTNAME=''
  HOSTINFO=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' 'https://'$RUBRIK'/api/v1/host/'$TARGET_HOSTID -k -1 -s)
  TARGET_HOSTNAME=$(echo $HOSTINFO | jq -r '.name')

  if [ "$TARGET_HOSTNAME" = '' ]
  then
    echo "ERROR: No TARGET_HOSTID found. ABORTING"
    exit 1
  fi
fi

# Grabs the info and snapshot list for the Source Fileset ID
FILESETINFO=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID -k -1 -s)

# Initiate an array to store the snapshot IDs and dates
# The oldest snapshot will be the first index in the array (array[1])
SNAPSHOTIDS=()
SNAPSHOTDATES=()

# Get the snapshots from the fileset data
SNAPSHOTINFO=$(echo $FILESETINFO | jq -c '.snapshots[]')

# Loop through the snapshots and pull out the snapshot IDs and dates
while read -r line
do
  SNAPSHOTIDS+=($(echo $line | jq -r '.id'))
  SNAPSHOTDATES+=($(echo $line | jq -r '.date'))
done <<< "$SNAPSHOTINFO"

# List out all the snapshots found and the corresponding array index for selection
echo -e "\n##  Snapshot Dates (UTC)"
echo "--  --------------------"

i=0
while [ $i -lt ${#SNAPSHOTDATES[@]} ]
do
  printf '%-3s %-20s\n' $i ${SNAPSHOTDATES[$i]}
  ((i++))
done

USERSNAPSHOT=-1

# Prompts for which snapshot # to recover from with some lightweight checking
while [[ $USERSNAPSHOT -lt 0 || $USERSNAPSHOT -ge ${#SNAPSHOTDATES[@]} ]]
do
  echo -e -n "\nEnter snapshot # to recover from:  "
  read USERSNAPSHOT

  if [[ $USERSNAPSHOT -lt 0 || $USERSNAPSHOT -ge ${#SNAPSHOTDATES[@]} ]]
   then
    echo "Selection outside acceptable range, try again"
  fi
done

# Sets the snapshot ID that is selected by the user to $SNAPSHOTIDTORESTORE
SNAPSHOTIDTORESTORE=${SNAPSHOTIDS[$USERSNAPSHOT]}

# Lists out the details of the snapshot selected for review
echo -e "\nRestoring from: ${SNAPSHOTDATES[$USERSNAPSHOT]} UTC; snapshot ID: $SNAPSHOTIDTORESTORE"

if [ "$TARGET_HOSTID" != '' ]
then
  echo "Target hostname: $TARGET_HOSTNAME; host ID: $TARGET_HOSTID"
else
  echo "Restoring to same host since no target host id was configured"
fi

echo -e "Fileset ID: $FILESETID\n"
echo "Source Directory  to  Target Directory"
echo "--------------------------------------"

i=0
while [ $i -lt ${#SOURCE_DIR[@]} ]
do
  echo "${SOURCE_DIR[$i]}  to  ${TARGET_DIR[$i]}"
  ((i++))
done

# Checks that the user wants to proceed by typing 'y'. Otherwise, exits script
echo -e -n "\nType 'y' to proceed:  "
read USERPROCEED

if [ "$USERPROCEED" != 'y' ]
then
  echo "Exiting script"; exit 2
fi

# Create JSON for restore body
RESTORE_JSON='{ "restoreConfig": [ '

# Loop through all the source directories to create JSON body
SOURCECOUNT=0
while [ $SOURCECOUNT -lt ${#SOURCE_DIR[@]} ]
do
  # Get the list of files and sub-folders under the source directory
  DIRINFO=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' \
    'https://'$RUBRIK'/api/internal/browse?limit=500&snapshot_id='$SNAPSHOTIDTORESTORE'&path='${SOURCE_DIR[$SOURCECOUNT]} -k -1 -s)

  # Test if the source directory info was returned, and if not, exit script
  TESTDIRINFO=$(echo $DIRINFO | jq -r '.data[].filename')
  if [ "$TESTDIRINFO" = '' ]
  then
    echo "ERROR: Invalid path info for source directory: ${SOURCE_DIR[$SOURCECOUNT]}. ABORTING"
    exit 1
  else
    # Create an array of all the files and sub-folders (paths) under the source directory
    PATHLIST=()

    PATHINFO=$(echo $DIRINFO | jq -r '.data[].filename')
    while read -r line
    do
      PATHLIST+=($line)
    done <<< $PATHINFO
  fi

  # Loop through each path, create a JSON for the source-target pair, and add to the restore JSON body
  PATHCOUNT=0
  while [ $PATHCOUNT -lt ${#PATHLIST[@]} ]
  do
    PATHBODY='{ "path": "'${SOURCE_DIR[$SOURCECOUNT]}'/'${PATHLIST[$PATHCOUNT]}'", "restorePath": "'${TARGET_DIR[$SOURCECOUNT]}'" }'
    RESTORE_JSON+=$PATHBODY
    ((PATHCOUNT++))

    # Check if this is the last path to be added, and if not, add ", " to the JSON body
    if [ $PATHCOUNT -lt ${#PATHLIST[@]} ]
    then
      RESTORE_JSON+=', '
    fi
  done  # while [ $PATHCOUNT -le ${#PATHLIST[@]} ]
  ((SOURCECOUNT++))

  # Check if this is the last source directory to be processed, and if not, add ", " to the JSON body
  if [ $SOURCECOUNT -lt ${#SOURCE_DIR[@]} ]
  then
    RESTORE_JSON+=', '
  fi
done  # while [ $SOURCECOUNT -le ${#SOURCE_DIR[@]} ]

# Complete JSON for the restore body
RESTORE_JSON+=' ], "ignoreErrors": false }'

echo "Restore request:"
echo $RESTORE_JSON | jq

# Invoke the restore task
RESULT=$(curl -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$RESTORE_JSON" 'https://'$RUBRIK'/api/internal/fileset/snapshot/'$SNAPSHOTIDTORESTORE'/restore_files' -k -1 -s)
echo $RESULT

if [ $MONITOR -ne 0 ]; then
  # Reset $STATUS in case it contains other values
  STATUS=""

  # Pull out the URL that we use to query status
  HREF=$(echo $RESULT | sed -e 's/.*href\"\:\"\(.*\)\"\,.*/\1/')
  RUBRIKSTATUS=0

  while [ $RUBRIKSTATUS -eq 0 ]
  do
    # Query the URL for the current status of the on demand backup
    STATUS=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' "$HREF" -k -1 -s)

    # Check if any of the end states are found, if so, $RUBRIKSTATUS changes and loop exits
    RUBRIKSTATUS=$(echo $STATUS | grep 'SUCCESS\|SUCCESSWITHWARNINGS\|FAILURE\|CANCELED' -c)

    echo $STATUS
    sleep 30
  done

  echo $STATUS
fi
