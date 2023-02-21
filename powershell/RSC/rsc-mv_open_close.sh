#!/bin/bash
# Requires 'curl'
# Requires 'jq'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 2/5/23

# This script will open or close a MV
# 'rsc-mv_open_close.sh open' - Open the MV for write
# 'rsc-mv_open_close.sh close' - Close the MV to read-only and take a snapshot
# Always assign the MV a SLA and close the MV to take a snapshot when done writing backups

# For authentication, use a RSC Service Account with a RBAC role assigned to it.
# The RBAC role only needs the "Take On Demand Snapshot" privilege for the
# managed volumes that it will be opening / closing.


### RUBRIK VARIABLES - BEGIN ###
# For authentication, use the RSC client_id and client_secret from the json
CLIENT_ID=''
CLIENT_SECRET=''

# RSC base URL
RSC_URL='customer.my.rubrik.com'

# Managed Volume ID - grab it from the URL of the MV
MV_ID='ca62b0dc-4175-5eca-828c-6393859f6319'

# Script execution time
LAUNCHTIME=`date +%Y-%m-%d_%H%M%S`
### RUBRIK VARIABLES - END ###

echo "### Starting script rsc-mv_open_close.sh ###"
echo "Using shell: $SHELL"
echo "Script time: $LAUNCHTIME"
echo ""

### Check to ensure the json utility jq is installed
command -v jq >/dev/null 2>&1 || { echo >&2 "Script requires the utility jq. Aborting."; exit 1; }

# If no arguments are provided, display help and exit
if [ $# -eq 0 ]; then
  help
  exit 1
fi

# Define headers and base URL for curl REST API calls
RSC_HEADER='Content-Type: application/json'
RSC_AUTH_URL='https://'$RSC_URL'/api/client_token'
RSC_PAYLOAD='{ "grant_type": "client_credentials", "client_id": "'$CLIENT_ID'", "client_secret": "'$CLIENT_SECRET'" }'
RSC_RESPONSE=$(curl -ks -X POST -H "$RSC_HEADER" -d "$RSC_PAYLOAD" "$RSC_AUTH_URL")
RSC_ACCESS_TOKEN=$(echo $RSC_RESPONSE | jq '.access_token' -r)

RSC_URL='https://'$RSC_URL'/api/graphql'
RSC_AUTH_HEADER='Authorization:bearer '
RSC_AUTH_HEADER+=$RSC_ACCESS_TOKEN

# Find the cluster ID
RSC_CLUSTER_PAYLOAD='{"query":"query ($filter: ClusterFilterInput) {\n clusterConnection(filter: $filter) {\n edges {\n node {\n id\n  name\n type\n version\n }\n }\n }\n }","variables":{"filter":{"name":["'$CLUSTER'"]}}}'
RSC_CLUSTER_RESPONSE=$(curl -ks -X POST -H "$RSC_HEADER" -H "Authorization: Bearer $RSC_ACCESS_TOKEN" -d "$RSC_CLUSTER_PAYLOAD" "$RSC_URL")
CLUSTER_ID=$(echo $RSC_CLUSTER_RESPONSE | jq '.data.clusterConnection.edges[0].node.id' -r)

if [ $1 == 'open' ]; then
  # Open the Managed Volume into read-write state
  echo "Opening Managed Volume for write: $MV_ID"
  RSC_OPEN_PAYLOAD='{"query":"mutation ($input: BeginManagedVolumeSnapshotInput!) {\n beginManagedVolumeSnapshot(input: $input) {\n asyncRequestStatus {\n id\n }\n }\n }","variables":{"input":{"config":{"isAsync":true},"id":"'$MV_ID'"}}}'
  RSC_OPEN_RESPONSE=$(curl -ks -X POST -H "$RSC_HEADER" -H "Authorization: Bearer $RSC_ACCESS_TOKEN" -d "$RSC_OPEN_PAYLOAD" "$RSC_URL")
  exit 0
elif [ $1 == 'close' ]; then
  # Close the Managed Volume into read-only state
  echo "Closing Managed Volume to read-only: $MV_ID"
  RSC_CLOSE_PAYLOAD='{"query":"mutation ($input: EndManagedVolumeSnapshotInput!) {\n endManagedVolumeSnapshot(input: $input) {\n asyncRequestStatus {\n id\n }\n }\n }","variables":{"input":{"params":{"isAsync":true},"id":"'$MV_ID'"}}}'
  RSC_CLOSE_RESPONSE=$(curl -ks -X POST -H "$RSC_HEADER" -H "Authorization: Bearer $RSC_ACCESS_TOKEN" -d "$RSC_CLOSE_PAYLOAD" "$RSC_URL")
  exit 0
fi

echo "Use an argument 'open' or 'close' - exiting"
exit 1
