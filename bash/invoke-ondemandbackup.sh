#!/bin/bash

# This script will take an on demand backup of a fileset

################################################################################
### RUBRIK VARIABLES
#Configure using an API token for authentication
TOKEN=''
#Configure using a username:password for authenciation
#The username:password can be encoded as a base64 string.
#Use 'echo -n "admin:GoRubrik123" | base64' to generate with most Linux distros
USER_PASS=''
#Configure hostname or IP address of your Rubrik cluster
RUBRIK=''
#Fileset ID that you want to trigger on demand backup on
FILESETID=''
#SLA ID you want to associate with the on demand backup
SLAID=''
#Set MONITOR to non-zero if you want the script to monitor progress until the backup has finished
MONITOR=0
#Script execute time
LOGPATH= #SomePath
LAUNCHTIME=`date +%m%d%y_%H%M%S`
################################################################################

if [ "$TOKEN" != "" ]
then
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
else
  AUTH_HEADER='Authorization:basic '
  AUTH_HEADER+=$USER_PASS
  echo $AUTH_HEADER
fi

JSON='{"slaId": "'"$SLAID"'"}'

if [ "$MONITOR" -eq 0 ]
then
  curl -H "$AUTH_HEADER" -X POST -H 'Content-Type: application/json' -d "$JSON" 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'/snapshot' -k
else
  STATUS=""
  RESULT=$(curl -H "$AUTH_HEADER" -X POST -H 'Content-Type: application/json' -d "$JSON" 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'/snapshot' -k)

  HREF=$(echo $RESULT | sed -e 's/.*href\"\:\"\(.*\)\"\,.*/\1/')
  RUBRIKSTATUS=0

  while [ $RUBRIKSTATUS -eq 0 ]
  do
    STATUS=$(curl -H "$AUTH_HEADER" -X GET -H 'Content-Type: application/json' "$HREF" -k)
    RUBRIKSTATUS=$(echo $STATUS | grep 'SUCCESS\|SUCCESSWITHWARNINGS\|FAILURE\|CANCELED' -c)

    echo $STATUS
    sleep 10
  done

  echo $STATUS
fi
