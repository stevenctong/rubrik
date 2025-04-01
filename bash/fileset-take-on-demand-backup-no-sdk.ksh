#!/bin/ksh
# Requires 'curl' and 'jq'
# Written by Steven Tong for community usage
# Date: 3/8/25
#
# Rubrik Security Cloud (RSC) Service Account is required
# Create a RSC Service Account and assign it a role with "Take On Demand Backup"
# permission for the Fileset.
#
# CDM Fileset ID & SLA ID can be gathered by browsing to Infrastructure -> Cluster,
# "Visit Cluster" to log into the local cluster UI.
# Then browse to the Fileset you want to backup and grab the Fileset ID from
# the URL at the end. It should look like: "Fileset:::9b603ba0-5964-476d-8eb6-e6c85b4d4663".
# SLA ID - browse to the SLA you want to use. It should look like: "a59a4b68-f7a8-44a1-93ff-5811f056caf3"
# If the RSC SLA needs to be sync'ed down to the local cluster you can go to
# RSC -> SLA Domains -> Select the SLA Domain -> "..." -> Sync with Local Cluster.

# Current Date
DATE=$(date +%Y-%m-%d_%H%M)
LOGFILE=./rubrik_script-${DATE}.log
touch $LOGFILE

### VARIABLES - START ###
# Rubrik cluster hostname or IP
cluster="10.8.48.104"
# RSC Service Account - should have 'take on demand backup' permission
serviceAccountPath="./rsc-service-account-rr.json"
# CDM Fileset ID
filesetID="Fileset:::9b603ba0-5964-476d-8eb6-e6c85b4d4663"
# CDM SLA ID
slaID="a59a4b68-f7a8-44a1-93ff-5811f056caf3"
# Set to true if you want script to continue checking status until completed
loopStatusCheck=false
# Rubrik end state job statuses
set -A jobFinishedStatuses Succ Fail Cancel

# If enabling emailing
# sendMail=false
# emailSubject="Rubrik - On Demand Fileset Backup - "
# emailFrom="sender@example.com"
# emailTo="recipient@example.com"
# SMTPServer="smtp.example.com"
# SMTPPort="25"

### VARIABLES - END ###

# Function to print error message and exit
error_exit() {
    echo "$1" >&2
    exit 1
}

# Function to make authenticated REST calls
authenticated_request() {
    typeset method=$1
    typeset url=$2
    typeset data=$3
    # Make the request
    response=$(curl -s -k -X $method -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$data" "$url")
    if [[ $? -ne 0 ]]; then
        error_exit "Error making request to $url"
    fi
    echo "$response"
}

main() {
  ###### RUBRIK AUTHENTICATION - BEGIN ######
  echo "Info: Attempting to read the Service Account file located at $serviceAccountPath"
  serviceAccountFile=$(cat "$serviceAccountPath") || error_exit "The Service Account JSON secret file was not found. Ensure the file is located at $serviceAccountPath."
  clientId=$(echo "$serviceAccountFile" | jq -r .client_id)
  clientSecret=$(echo "$serviceAccountFile" | jq -r .client_secret)
  accessTokenUri=$(echo "$serviceAccountFile" | jq -r .access_token_uri)

  if [[ -z "$clientId" || -z "$clientSecret" || -z "$accessTokenUri" ]]; then
      error_exit "The Service Account JSON secret file is missing required parameters."
  fi

  response=$(curl -s -k -X POST -H "Content-Type: application/json" \
    -d "{\"serviceAccountId\": \"$clientId\", \"secret\": \"$clientSecret\"}" \
    "https://$cluster/api/v1/service_account/session")
  token=$(echo "$response" | jq -r .token)

  if [[ -n "$token" ]]; then
      echo "Connected to Rubrik cluster: $cluster"
  else
      error_exit "Could not connect to Rubrik cluster: $cluster"
  fi
  ###### RUBRIK AUTHENTICATION - END ######

  # Get Fileset info
  filesetInfo=$(authenticated_request GET "https://$cluster/api/v1/fileset/$filesetID")
  filesetName=$(echo "$filesetInfo" | jq -r .name)
  if [[ -z "$filesetName" || "$filesetName" == "null" ]]; then
    error_exit "Could not find Fileset: $filesetID"
  fi
  echo "Found fileset: $filesetName, with Fileset ID: $filesetID"

  # Get last few backup events for the Fileset
  eventInfo=$(authenticated_request GET "https://$cluster/api/v1/event/latest?event_type=Backup&object_ids=$filesetID")

  # Get the most recent and second most recent backup events
  lastBackupEvent=$(echo "$eventInfo" | jq -r .data[0].latestEvent)
  lastBackupTime=$(echo "$lastBackupEvent" | jq -r .time)
  lastBackupStatus=$(echo "$lastBackupEvent" | jq -r .eventStatus)
  lastTwoBackupEvent=$(echo "$eventInfo" | jq -r .data[1].latestEvent)
  lastTwoBackupTime=$(echo "$lastTwoBackupEvent" | jq -r .time)
  lastTwoBackupStatus=$(echo "$lastTwoBackupEvent" | jq -r .eventStatus)

  echo ""
  echo "Last backup time: $lastBackupTime"
  echo "Last backup status: $lastBackupStatus"
  echo "Second to last backup time: $lastTwoBackupTime"
  echo "Second to last backup status: $lastTwoBackupStatus"
  echo ""

  activeJob=true
  for status in "${jobFinishedStatuses[@]}"; do
      if [[ "$lastBackupStatus" == *queue* ]]; then
        echo "Last backup was QUEUED, checking previous backup for status."
        if [[ "$lastTwoBackupStatus" == *"$status"* ]]; then
            activeJob=false
            break
        fi
      else
        if [[ "$lastBackupStatus" == *"$status"* ]]; then
          activeJob=false
          break
        fi
      fi
  done

  if [[ "$activeJob" == true ]]; then
      error_exit "Previous backup event is still active, exiting..."
  fi

  # Get SLA info
  slaInfo=$(authenticated_request GET "https://$cluster/api/v2/sla_domain/$slaID")
  slaName=$(echo "$slaInfo" | jq -r .name)
  slaCount=$(echo "$slaInfo" | jq -r .count)
  if [[ -z "$slaName" || "$slaName" == "null" ]]; then
    error_exit "Could not find SLA: $slaID"
  fi
  echo "Found SLA: $slaName, with SLA ID: $slaID"

  echo "Attempting on demand Fileset backup of Fileset: $filesetName ($filesetID) with SLA: $slaName ($slaID)."

  filesetBody="{\"slaId\": \"$slaID\"}"
  response=$(authenticated_request POST "https://$cluster/api/v1/fileset/$filesetID/snapshot" "$filesetBody")

  echo "$response"

  if [[ "$loopStatusCheck" == true ]]; then
      href=$(echo "$response" | jq -r '.links[0].href')
      echo "Getting the status of the task."
      jobFinished=false
      while [[ "$jobFinished" == false ]]; do
          response=$(authenticated_request GET "$href")
          echo "Current status: $(echo "$response" | jq -r .status). Waiting 10 seconds..."
          for status in "${jobFinishedStatuses[@]}"; do
              if [[ "$(echo "$response" | jq -r .status)" == *"$status"* ]]; then
                  jobFinished=true
                  break
              fi
          done
          sleep 10
      done
      finalStatus=$(echo "$response" | jq -r .status)
      startTime=$(echo "$response" | jq -r .startTime)
      endTime=$(echo "$response" | jq -r .endTime)
      # Send an email when completed - this block has not been verified
      if [[ "$sendEmail" == true ]]; then
          # Build the HTML report
          htmlReport="<html>
          <body>
          <p>Status: $finalStatus</p>
          <p>Fileset: $filesetName ($filesetID)</p>
          <p>Start time: $startTime</p>
          <p>End time: $endTime</p>
          </body>
          </html>"
          # Build the email content with headers
          emailContent="To: $emailTo
          Subject: $emailSubject
          From: $emailFrom
          Content-Type: text/html
          $htmlReport"
          # Send the email using sendmail
          echo "$emailContent" | sendmail -t
      fi
  fi
}

main >> $LOGFILE 2>&1
