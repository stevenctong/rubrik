#!/bin/bash
# Requires 'curl' and 'jq'
# Written by Steven Tong for community usage
# Date: 3/8/25

# Variables (can be set as required)
cluster="10.8.48.104"
serviceAccountPath="./rsc-service-account-rr.json"
filesetID="Fileset:::9b603ba0-5964-476d-8eb6-e6c85b4d4663"
slaID="a59a4b68-f7a8-44a1-93ff-5811f056caf3"
loopStatusCheck=false
jobFinishedStatuses=("SUCC" "FAIL" "CANCELED")

# If enabling emailing
# sendMail=false
# emailSubject="Rubrik - On Demand Fileset Backup - "
# emailFrom="sender@example.com"
# emailTo="recipient@example.com"
# SMTPServer="smtp.example.com"
# SMTPPort="25"

# Function to print error message and exit
function error_exit {
    echo "$1" 1>&2
    exit 1
}

# Function to make authenticated REST calls
function authenticated_request {
    local method=$1
    local url=$2
    local data=$3
    # Make the request
    response=$(curl -s -k -X $method -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$data" "$url")
    if [ $? -ne 0 ]; then
        error_exit "Error making request to $url"
    fi
    echo "$response"
}

# Current Date
date=$(date +"%Y-%m-%d %H:%M")

###### RUBRIK AUTHENTICATION - BEGIN ######
echo "Info: Attempting to read the Service Account file located at $serviceAccountPath"
serviceAccountFile=$(cat "$serviceAccountPath") || error_exit "The Service Account JSON secret file was not found. Ensure the file is located at $serviceAccountPath."
clientId=$(echo "$serviceAccountFile" | jq -r .client_id)
clientSecret=$(echo "$serviceAccountFile" | jq -r .client_secret)
accessTokenUri=$(echo "$serviceAccountFile" | jq -r .access_token_uri)

if [ -z "$clientId" ] || [ -z "$clientSecret" ] || [ -z "$accessTokenUri" ]; then
    error_exit "The Service Account JSON secret file is missing required parameters."
fi

response=$(curl -s -k -X POST -H "Content-Type: application/json" \
  -d "{\"serviceAccountId\": \"$clientId\", \"secret\": \"$clientSecret\"}" \
  "https://$cluster/api/v1/service_account/session")
token=$(echo "$response" | jq -r .token)

if [ -n "$token" ]; then
    echo -e "\033[0;32mConnected to Rubrik cluster: $cluster\033[0m"
else
    error_exit "Could not connect to Rubrik cluster: $cluster"
fi
###### RUBRIK AUTHENTICATION - END ######

# Get Fileset info
filesetInfo=$(authenticated_request GET "https://$cluster/api/v1/fileset/$filesetID")
filesetName=$(echo "$filesetInfo" | jq -r .name)
echo -e "\033[0;32mFound fileset: $filesetName, with Fileset ID: $filesetID\033[0m"

# Get last few backup events for the Fileset
eventInfo=$(authenticated_request GET "https://$cluster/api/v1/event/latest?event_type=Backup&object_ids=$filesetID")
lastBackupEvent=$(echo "$eventInfo" | jq -r .data[0].latestEvent)
lastBackupTime=$(echo "$lastBackupEvent" | jq -r .time)
lastBackupStatus=$(echo "$lastBackupEvent" | jq -r .eventStatus)

echo ""
echo -e "\033[0;32mLast backup time: $lastBackupTime\033[0m"
echo -e "\033[0;32mLast backup status: $lastBackupStatus\033[0m"
echo ""

shopt -s nocasematch
activeJob=true
for status in "${jobFinishedStatuses[@]}"; do
    # Debug: Show the status being compared
    echo "Comparing with status: $status"
    echo $lastBackupStatus
    if [[ "$lastBackupStatus" == *"$status"* ]]; then
        activeJob=false
        break
    fi
done

if [ "$activeJob" = true ]; then
    echo "Previous backup event is still active, exiting..."
    exit 0
fi

# Get SLA info
slaInfo=$(authenticated_request GET "https://$cluster/api/v2/sla_domain/$slaID")
slaName=$(echo "$slaInfo" | jq -r .name)
slaCount=$(echo "$slaInfo" | jq -r .count)
echo -e "\033[0;32mFound SLA: $slaName, with SLA ID: $slaID\033[0m"

echo -e "\033[0;32mAttempting on demand Fileset backup of Fileset: $filesetName ($filesetID) with SLA: $slaName ($slaID).\033[0m"

filesetBody="{\"slaId\": \"$slaID\"}"
response=$(authenticated_request POST "https://$cluster/api/v1/fileset/$filesetID/snapshot" "$filesetBody")

echo "$response"

if [ "$loopStatusCheck" = true ]; then
    href=$(echo "$response" | jq -r '.links[0].href')
    echo "Getting the status of the task."
    jobFinished=false
    while [ "$jobFinished" = false ]; do
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
    shopt -u nocasematch
    finalStatus=$(echo "$response" | jq -r .status)
    startTime=$(echo "$response" | jq -r .startTime)
    endTime=$(echo "$response" | jq -r .endTime)
    # Send an email when completed - this block has not been verified
    if [ "$sendEmail" = true ]; then
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
