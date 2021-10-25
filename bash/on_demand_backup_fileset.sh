#!/bin/bash
# Requires 'curl'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 1/6/21, updated: 10/24/21

# This script will take an on demand backup of a fileset with a corresponding SLA.
# Create a custom role to limit the privileges of the script user.

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
# Fileset ID that you want to trigger on demand backup on
FILESETID=''
# SLA ID you want to associate with the on demand backup
SLAID=''
# Set MONITOR to non-zero if you want the script to monitor progress until the backup has finished
MONITOR=0
# Script execution time
LOGPATH= #SomePath
LAUNCHTIME=`date +%m%d%y_%H%M%S`
### RUBRIK VARIABLES - END ###

# If an API token is provided, use that. Otherwise, try using the encoded username/password
if [ "$TOKEN" != '' ]
then
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
else
  AUTH_HEADER='Authorization:basic '
  AUTH_HEADER+=$USER_PASS
fi

JSON='{"slaId": "'$SLAID'"}'

# Trigger on demand backup using curl
RESULT=$(curl -H "$AUTH_HEADER" -X POST -H 'Content-Type: application/json' -d "$JSON" 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'/snapshot' -k -1 -s)
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
