# !/bin/bash
# Requires 'curl' and 'jq'
# https://build.rubrik.com
# Written by Steven Tong for community usage
# Date: 1/31/21

# This script will pull stats from a Rubrik cluster into a log file
# The log file can be picked up by Filebeat and sent to ELK

###### RUBRIK VARIABLES - BEGIN ######
# Rubrik configuration file location with cluster and API token list
RUBRIKCONF='/home/rubrik_clusters.conf'
# Path to store log output
LOGPATH='/var/log/rubrikelk'
# Current date to append to log output
DATE=`date +%Y-%m-%d`
###### RUBRIK VARIABLES - END ######

# Check to ensure the json utility jq is installed
command -v jq >/dev/null 2>&1 || { echo >&2 "Script requires the utility jq. Aborting."; exit 1; }

# Source config file that Rubrik clusters and API tokens are stored in
source ${RUBRIKCONF}

# Get UTC time script is run to insert into output
# The metric times must align for things like space or else it will not add up correctly
SCRIPTTIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SCRIPTTIMEJSON="{\"scriptRunTime\":\"${SCRIPTTIME}\"}"

# Checks if the number of Rubrik clusters and API tokens are the same
if [ ${#RUBRIKCLUSTERS[@]} != ${#RUBRIKTOKENS[@]} ]
then
  echo "# of RUBRIKCLUSTERS is not equal to RUBRIKTOKENS in config file. Aborting."; exit 1
fi

for i in "${!RUBRIKCLUSTERS[@]}"
do
  printf "Gathering stats for %s\t%s\n" "${RUBRIKCLUSTERS[$i]}" "$i"

  # Set $RUBRIK to current Rubrik cluster
  RUBRIK=${RUBRIKCLUSTERS[$i]}

  # Create curl authentication header using API token
  AUTH_HEADER='Authorization:bearer '${RUBRIKTOKENS[$i]}

  # Get Rubrik cluster name
  if CLUSTERNAME=$(curl -X GET "https://${RUBRIK}/api/internal/cluster/me/name" -H "accept: application/json" -H "${AUTH_HEADER}" -k -1 --fail)
  then

    # Base JSON where we will add additional stats to as we gather them
    RUBRIKJSON="{\"rubrikClusterName\":${CLUSTERNAME}}"

    # Add script run time to the base JSON
    RUBRIKJSON=$(echo $RUBRIKJSON | jq --argjson obj "$SCRIPTTIMEJSON" '. += $obj')

    # Get Rubrik cluster storage stats
    if RUBRIKSTORAGE=$(curl -X GET "https://${RUBRIK}/api/internal/stats/system_storage" -H "accept: application/json" -H "${AUTH_HEADER}" -k -1 --fail)
    then
      # Calculate the Rubrik cluster used % and add to the storage stats json
      RUBRIKTOTALCAP=$(echo $RUBRIKSTORAGE | jq .total)
      RUBRIKUSEDCAP=$(echo $RUBRIKSTORAGE | jq .used)
      RUBRIKUSEDPCT=$(echo "scale=3 ; ${RUBRIKUSEDCAP} / ${RUBRIKTOTALCAP} * 100" | bc)

      RUBRIKUSEDPCTTJSON="{\"rubrikUsedPct\":${RUBRIKUSEDPCT}}"
      RUBRIKSTORAGE=$(echo $RUBRIKSTORAGE | jq --argjson obj "$RUBRIKUSEDPCTTJSON" '. += $obj')

      RUBRIKJSON=$(echo ${RUBRIKJSON} ${RUBRIKSTORAGE} | jq -s add)
    fi

    # Get Rubrik dashboard SLA compliance
    if RUBRIKCOMPLIANCE=$(curl -X GET "https://${RUBRIK}/api/v1/report/compliance_summary_sla?snapshot_range=LastSnapshot" -H "accept: application/json" -H "${AUTH_HEADER}" -k -1 --fail)
    then
      RUBRIKJSON=$(echo ${RUBRIKJSON} ${RUBRIKCOMPLIANCE} | jq -s add)
    fi

    # Get status of each Rubrik node in the cluster and provide the number good, bad, and total nodes
    if RUBRIKNODES=$(curl -X GET "https://${RUBRIK}/api/internal/cluster/me/node" -H "accept: application/json" -H "${AUTH_HEADER}" -k -1 --fail)
    then
      GOODNODES=0
      BADNODES=0
      TOTALNODES=0

      while read i
      do
        ((TOTALNODES++))
        echo $i | jq .status
        if [ $(echo $i | jq .status)  == '"OK"' ]
        then
          ((GOODNODES++))
        else
          ((BADNODES++))
        fi
      done < <(echo $RUBRIKNODES | jq -c '.data[]')

      RUBRIKGOODNODESJSON="{\"rubrikNodesGood\":${GOODNODES}}"
      RUBRIKJSON=$(echo ${RUBRIKJSON} ${RUBRIKGOODNODESJSON} | jq -s add)

      RUBRIKBADNODESJSON="{\"rubrikNodesBad\":${BADNODES}}"
      RUBRIKJSON=$(echo ${RUBRIKJSON} ${RUBRIKBADNODESJSON} | jq -s add)

      RUBRIKTOTALNODESJSON="{\"rubrikNodesTotal\":${TOTALNODES}}"
      RUBRIKJSON=$(echo ${RUBRIKJSON} ${RUBRIKTOTALNODESJSON} | jq -s add)
    fi


    # Write storage stats json to log file
    echo ${RUBRIKJSON} >> ${LOGPATH}/rubrik_stats_${DATE}.log

  fi
done
