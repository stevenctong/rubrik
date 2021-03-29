# !/bin/bash
# Requires 'curl' and 'jq'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 12/10/20

# This script will restore a fileset to an alternate host (fileset export).
# A list of source and target directories must be provided.
# The script will list the available snapshots for the fileset so the user can select a point in time for restore.
# Once selected the script will kick off a restore job for each source-target directory pair.

################################################################################
### RUBRIK VARIABLES
# Configure using an API token for authentication
TOKEN='apitokenstring'
# Alternatively, configure authentication using a 'username:password'
# The 'username:password' can be encoded as a base64 string
# Use 'echo -n "admin:GoRubrik123" | base64' to generate with most Linux distros
USER_PASS=''
# Configure hostname or IP address of your Rubrik cluster
RUBRIK='rubrikhostname'
# SOURCE Fileset ID that you want to restore from
FILESETID='Fileset:::36ca4a05-8625-4595-983c-fcfef805997c'
# SOURCE List of directories to restore, separated by a space in the array
RESTORE_DIR=('/epic/prd01' '/epic/prd02')
# TARGET List of directories to restore to. Align to the order listed in $RESTORE_DIR
TARGET_DIR=('/target/prd01' '/target/prd02')
# TARGET Host ID that you want to restore to
TARGET_HOSTID='Host:::cd4495b1-fe38-4b60-8b43-077fbd746c8d'
# Script execution time
LOGPATH= #SomePath
LAUNCHTIME=`date +%m%d%y_%H%M%S`
################################################################################

### Check to ensure the json utility jq is installed
command -v jq >/dev/null 2>&1 || { echo >&2 "Script requires the utility jq. Aborting."; exit 1; }

# If an API token is provided, use that. Otherwise, use username password
if [ "$TOKEN" != "" ]
then
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
else
  AUTH_HEADER='Authorization:basic '
  AUTH_HEADER+=$USER_PASS
  echo $AUTH_HEADER
fi

# Checks if the number of restore directories to target directories is equal, exits on error
if [ ${#RESTORE_DIR[@]} != ${#TARGET_DIR[@]} ]
then
  echo "# of RESTORE_DIR is not equal to TARGET_DIR. Aborting."; exit 1
fi

# Gets the hostname of the Target Host ID and exits if the host is not found
TARGET_HOSTNAME=''
HOSTINFO=$(curl -H $AUTH_HEADER -X GET -H 'Content-Type: application/json' -d '' 'https://'$RUBRIK'/api/v1/host/'$TARGET_HOSTID'' -k -1)
TARGET_HOSTNAME=$(echo $HOSTINFO | jq -r '.name')

if [[ $TARGET_HOSTNAME = '' ]]
then
  echo "Error - No TARGET_HOSTID found. Aborting."; exit 1
fi

# Grabs the info and snapshot list for the Source Fileset ID
FILESETINFO=$(curl -H $AUTH_HEADER -X GET -H 'Content-Type: application/json' 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'' -k -1)

# The list of snapshot IDs and dates will be stored in an array
# The oldest snapshot will be the first index in the array (array[1])
SNAPSHOTIDS=()
SNAPSHOTDATES=()

# The list of snapshots is under the key 'snapshots' as an array
# Loop through all the snapshots and pull out the snapshot ID and date
echo $FILESETINFO | jq -c '.snapshots[]' | while read keydata
  do
    SNAPSHOTIDS+=$(echo $keydata | jq -r '.id')
    SNAPSHOTDATES+=$(echo $keydata | jq -r '.date')
done

# List out all the snapshots found and the corresponding array index for selection
echo "\n##  Snapshot Dates (UTC)"
echo "--  --------------------"

i=1
while [ $i -le ${#SNAPSHOTDATES[@]} ]
do
  printf '%-3s %-20s\n' $i $SNAPSHOTDATES[$i]
  ((i++))
done

USERSNAPSHOT=0

# Prompts for which snapshot # to recover from with some lightweight checking
while [[ $USERSNAPSHOT -lt 1 || $USERSNAPSHOT -gt ${#SNAPSHOTDATES[@]} ]]
do
  echo -n "\nEnter snapshot # to recover from:  "
  read USERSNAPSHOT

  if [[ $USERSNAPSHOT -lt 1 || $USERSNAPSHOT -gt ${#SNAPSHOTDATES[@]} ]]
   then
    echo "Input outside acceptable range."
  fi
done

# Sets the snapshot ID that is selected by the user to $SNAPSHOTIDTORESTORE
SNAPSHOTIDTORESTORE=$SNAPSHOTIDS[$USERSNAPSHOT]

# Lists out the details of the snapshot selected for review
echo "\nRestoring snapshot ID: $SNAPSHOTIDTORESTORE from $SNAPSHOTDATES[$USERSNAPSHOT] UTC"
echo "Target host ID: $TARGET_HOSTID, hostname $TARGET_HOSTNAME\n"
echo "Restore Directory  to  Target Directory  for  Fileset ID: $FILESETID"
echo "---------------------------------------"

i=1
while [ $i -le ${#RESTORE_DIR[@]} ]
do
  echo "$RESTORE_DIR[i]  to  $TARGET_DIR[i]"
  ((i++))
done

# Checks that the user wants to proceed by typing 'y'. Otherwise, exits script
echo -n "\nType 'y' to proceed:  "
read USERPROCEED

if [ $USERPROCEED != 'y' ]
 then
  echo "Exiting script"; exit 2;
fi

# If user wants to proceed, loop through all the source and target directories and trigger a restore export job for each
i=1
while [ $i -le ${#RESTORE_DIR[@]} ]
do
  CUR_RESTORE_DIR=$RESTORE_DIR[i]
  CUR_TARGET_DIR=$TARGET_DIR[i]
  echo "\n\nInitiating restore of $CUR_RESTORE_DIR  to  $CUR_TARGET_DIR"

  JSON='{ "sourceDir": "'"$CUR_RESTORE_DIR"'", "destinationDir": "'"$CUR_TARGET_DIR"'", "ignoreErrors": true, "hostId": "'"$TARGET_HOSTID"'" }'

  echo $JSON

  curl -X POST -H $AUTH_HEADER -H 'Content-Type: application/json' -d $JSON 'https://'$RUBRIK'/api/v1/fileset/snapshot/'$SNAPSHOTIDTORESTORE'/export_file' -k -1
  ((i++))
done
