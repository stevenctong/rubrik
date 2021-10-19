#!/bin/bash

# https://build.rubrik.com
# This script will take an on demand backup of a fileset
# For community usage

################################################################################
### RUBRIK VARIABLES
# Configure using an API token for authentication
TOKEN=''
# Configure using a username:password for authenciation
# The username:password can be encoded as a base64 string.
# Use 'echo -n "admin:GoRubrik123" | base64' to generate with most Linux distros
USER_PASS=''
# Configure hostname or IP address of your Rubrik cluster
RUBRIK=''
# Fileset ID that you want to trigger on demand backup on
FILESETID=''
# SLA ID you want to associate with the on demand backup
SLAID=''
# Set MONITOR to non-zero if you want the script to monitor progress until the backup has finished
MONITOR=0
# Script execute time
LOGPATH= #SomePath
LAUNCHTIME=`date +%m%d%y_%H%M%S`
################################################################################

# If an API token is provided, use that. Otherwise, try using the encoded username/password
if [ "$TOKEN" != "" ]
then
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
else
  AUTH_HEADER='Authorization:basic '
  AUTH_HEADER+=$USER_PASS
fi

JSON='{"slaId": "'"$SLAID"'"}'

if [ "$MONITOR" -eq 0 ]
then
  curl -H "$AUTH_HEADER" -X POST -H 'Content-Type: application/json' -d "$JSON" 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'/snapshot' -k
else
  # Reset $STATUS in case it contains other values
  STATUS=""

  # Store the result of our on demand snapshot
  RESULT=$(curl -H "$AUTH_HEADER" -X POST -H 'Content-Type: application/json' -d "$JSON" 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'/snapshot' -k)

  # Pull out the URL that we use to query status
  HREF=$(echo $RESULT | sed -e 's/.*href\"\:\"\(.*\)\"\,.*/\1/')
  RUBRIKSTATUS=0

  while [ $RUBRIKSTATUS -eq 0 ]
  do
    # Query the URL for the current status of the on demand backup
    STATUS=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' "$HREF" -k)

    # Check if any of the end states are found, if so, $RUBRIKSTATUS changes and loop exits
    RUBRIKSTATUS=$(echo $STATUS | grep 'SUCCESS\|SUCCESSWITHWARNINGS\|FAILURE\|CANCELED' -c)

    echo $STATUS
    sleep 10
  done

  echo $STATUS
fi
exit 0
