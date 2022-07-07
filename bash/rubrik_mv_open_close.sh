#!/bin/bash
# Requires 'curl'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 7/7/22

# This script will open or close a MV

# For authentication, use either an API token or base64 encoded username:password

### RUBRIK VARIABLES - BEGIN ###
# For authentication, use either an Service Account, API Token, Username+Password
# Configure a Service Account for authentication
SVC_ID='User:::d670b65c-8267-45fa-8dc0-678b6c63e488'
SVC_SECRET='/A1lS0aC8NJdC66HEqzPicul6cBPc+RQN1hsSpomdSOdSULFYJxKwVoWOQpm6VIGIEgzjH7eHEI7SKbedzWR'
# Configure an API token for authentication
TOKEN=''
# Configure a username:password for authenciation
# The username:password must be encoded as a base64 string.
# Use 'echo -n "admin:GoRubrik123" | base64' to generate with most Linux distros
USER_PASS=''
# Hostname or IP address of the Rubrik cluster
RUBRIK='amer1-rbk01.rubrikdemo.com'
# Managed Volume ID - grab it from the URL of the MV
MV_ID='ManagedVolume:::05191817-3198-40de-92b8-d9d4e48bd62e'
# Script execution time
LAUNCHTIME=`date +%Y-%m-%d_%H%M%S`
### RUBRIK VARIABLES - END ###


echo "### Starting script rubrik_mv_open_close.sh ###"
echo "Using shell: $SHELL"
echo "Script time: $LAUNCHTIME"
echo ""

# Define headers and base URL for curl REST API calls
TYPE_HEADER='Content-Type: application/json'
BASE_URL='https://'$RUBRIK'/api/'

# If an API token is provided, use that. Otherwise, use username password
if [ "$SVC_ID" != '' ]
then
  SVC_JSON='{ "serviceAccountId": "'$SVC_ID'", "secret": "'$SVC_SECRET'" }'
  SVC_RESULT=$(curl -k1s -X POST -H "$AUTH_HEADER" -H "$TYPE_HEADER" -d "$SVC_JSON" "$BASE_URL"'v1/service_account/session')
  TOKEN=$(echo $SVC_RESULT | sed -e 's/[{}]/''/g' | sed s/\"//g | awk -v RS=',' -F: '$1=="token"{print $2}')
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
elif [ "$TOKEN" != '' ]
then
  AUTH_HEADER='Authorization:bearer '
  AUTH_HEADER+=$TOKEN
else
  AUTH_HEADER='Authorization:basic '
  AUTH_HEADER+=$USER_PASS
fi

# Open the Managed Volume into read-write state
OPEN_MV=$(curl -k1s -X POST -H "$AUTH_HEADER" -H "$TYPE_HEADER" "$BASE_URL"'internal/managed_volume/'"$MV_ID"'/begin_snapshot')
echo $OPEN_MV

# Close the Managed Volume into read-only state
CLOSE_MV=$(curl -k1s -X POST -H "$AUTH_HEADER" -H "$TYPE_HEADER" "$BASE_URL"'internal/managed_volume/'"$MV_ID"'/end_snapshot')
echo $CLOSE_MV
