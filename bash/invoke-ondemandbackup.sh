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

curl -H "$AUTH_HEADER" -X POST -H 'Content-Type: application/json' -d "$JSON" 'https://'$RUBRIK'/api/v1/fileset/'$FILESETID'/snapshot' -k
