# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will find all emails within a date range and export the emails to PST.

.DESCRIPTION
This script will find all emails within a date range and export the emails to PST.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 10/8/23

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath



.EXAMPLE
./Rubrik-M365-Export-PST.ps1
Runs the script to to export the PST.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]

  # Sort order options: "Start time", "End time", "Duration", "Data transferred"
  [Parameter(Mandatory=$false)]
  [string]$sortOrder = 'Start time'
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Get emails from last specified days below, use a negative number
$pastDays = -90
$startDate = $utcDate.addDays($pastDays)

# Number of mailboxes to run the script gainst
$mailboxCount = 4

# Number of parallel theads to use
$throttleLimit = 8

# Whether save the report CSV for each run or not
$saveCSV = $true
$csvFileName = "./csvReports/rubrik_compliance_csv-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik M365 PST Export - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

### End Variables section

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
}
catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    throw "The Service Account JSON secret file was not found. Ensure the file is location at $serviceAccountPath."
  }
  throw $_.Exception
}

$payload = @{
  grant_type = "client_credentials";
  client_id = $serviceAccountFile.client_id;
  client_secret = $serviceAccountFile.client_secret
}

Write-Debug -Message "Determing if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($serviceAccountFile.client_id -eq $null) {
  $missingServiceAccount += "'client_id'"
}

if ($serviceAccountFile.client_secret -eq $null) {
  $missingServiceAccount += "'client_secret'"
}

if ($serviceAccountFile.access_token_uri -eq $null) {
  $missingServiceAccount += "'access_token_uri'"
}

if ($missingServiceAccount.count -gt 0){
  throw "The Service Account JSON secret file is missing the required paramaters: $missingServiceAccount"
}

$headers = @{
  'Content-Type' = 'application/json';
  'Accept' = 'application/json';
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

Write-Host "Successfully connected to: $rubrikURL."
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Get all M365 Subscriptions
Function Get-M365Subscriptions {
  $query = "query O365OrgCountAndComplianceQuery {
    o365Orgs {
      count
      edges {
        node {
          id
          name
          configuredSlaDomain {
            id
            name
          }
          __typename
        }
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  $m365Subscriptions = $response.data.o365Orgs.edges.node
  return $m365Subscriptions
}  ### Function Get-M365Subscriptions

# Get mailboxes in a subscription
Function Get-M365Mailboxes {
  param (
    [CmdletBinding()]
    # M365 Subscription ID
    [Parameter(Mandatory=$true)]
    [string]$subscriptionID,
    # Number of mailboxes to return
    [Parameter(Mandatory=$true)]
    [int]$mailboxCount
  )
  $variables = @{
    "orgId" = $subscriptionID
    "first" = $mailboxCount
    "filter" = @(
      @{
        "field" = "EXCLUDED_SHAREPOINT_LIBRARY_TYPE"
        "texts" = @(
          "WEB_PAGE_LIBRARY"
        )
      },
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "false"
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  $query = "query O365MailboxListQuery(`$first: Int!, `$after: String, `$orgId: UUID!, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    o365Mailboxes(o365OrgId: `$orgId, after: `$after, first: `$first, filter: `$filter, sortBy: `$sortBy, sortOrder: `$sortOrder) {
      edges {
        cursor
        node {
          id
          name
          userPrincipalName
          __typename
        }
        __typename
      }
      pageInfo {
        endCursor
        hasNextPage
        hasPreviousPage
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $mailboxes = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.o365Mailboxes.edges.node
  return $mailboxes
}  ### Function Get-M365Mailboxes

# Get the emails that are more recent than the provided number of days
Function Get-EmailList {
  param (
    [CmdletBinding()]
    # Subscription / Org ID
    [Parameter(Mandatory=$true)]
    [string]$orgID,
    # Mailbox ID to get emails for
    [Parameter(Mandatory=$true)]
    [string]$mailboxFID,
    # Starting date for search
    [Parameter(Mandatory=$true)]
    [DateTime]$startDate
  )
  $startDateUTC = $startDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
  $variables = @{
    "snappableFid" = $mailboxFID
    "orgId" = $orgID
    "searchFilter" = @{
      "searchKeywordFilter" = @{
        "searchKeyword" = ""
        "keywordType" = "SUBJECT"
      }
      "emailAddresses" = @()
      "fromTime" = $startDateUTC
    }

    "first" = 100
  }
  $query = "query (`$snappableFid: UUID!, `$searchFilter: SearchFilter, `$first: Int!, `$orgId: UUID!) {
    snappableEmailSearch(snappableFid: `$snappableFid, first: `$first, searchFilter: `$searchFilter, orgId: `$orgId) {
      edges {
        cursor
        node {
          ... on O365Email {
            id
            subject
            from
            toRecipients
            receivedDateTime
            snapshotId
            parentFolderId
            sentDateTime
            __typename
          }
          __typename
        }
        __typename
      }
      pageInfo {
        startCursor
        endCursor
        hasPreviousPage
        hasNextPage
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response.data.snappableEmailSearch.edges
} ### Function Get-EmailList

# Export emails to a PST
Function Export-EmailsPST {
  param (
    [CmdletBinding()]
    # Subscription / Org ID
    [Parameter(Mandatory=$true)]
    [string]$orgID,
    # Mailbox ID
    [Parameter(Mandatory=$true)]
    [string]$mailboxID,
    # Array of emails to export to PST
    [Parameter(Mandatory=$true)]
    [array]$emailList
  )
  $emailArray = @()
  foreach ($email in $emailList) {
    $emailItem = @{
      "EmailID" = $email.id
      "SnapshotUUID" = $email.snapshotId
    }
    $emailArray += $emailItem
  }
  $variables = @{
    "mailboxId" = $mailboxID
    "orgId" = $orgID
    "restoreConfigs" = $emailArray
    "actionType" = "EXPORT_SNAPPABLE"
  }
  $payload = @{
    "query" = "mutation (`$orgId: UUID, `$mailboxId: UUID!, `$restoreConfigs: [RestoreObjectConfig!]!, `$actionType: O365RestoreActionType!) {
      restoreO365Mailbox(restoreConfig: {mailboxUuid: `$mailboxId, restoreConfigs: `$restoreConfigs, orgUuid: `$orgId, actionType: `$actionType}) {
        taskchainId
        jobId
        __typename
      }
    }"
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response
}  ### Function Export-EmailsPST

# Get event series status
Function Get-EventStatus {
  param (
    [CmdletBinding()]
    # Activity / Taskchain ID
    [Parameter(Mandatory=$true)]
    [string]$taskChainID
  )
  $variables = @{
    "activitySeriesId" = $taskChainID
    "clusterUuid" = "00000000-0000-0000-0000-000000000000"
  }
  $query = "query (`$activitySeriesId: UUID!, `$clusterUuid: UUID) {
    activitySeries(input: {activitySeriesId: `$activitySeriesId, clusterUuid: `$clusterUuid}) {
      activityConnection {
        nodes {
          activityInfo
          message
          status
          time
          severity
          __typename
        }
        __typename
      }
      startTime
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  if ($response.errors) {
    return $response.errors
  }
  return $response.data.activitySeries.activityConnection.nodes
}  ### Function Get-EventStatus

# Get download link from event message
Function Get-DownloadLink {
  param (
    [CmdletBinding()]
    # Event message
    [Parameter(Mandatory=$true)]
    [string]$message,
    # Mailbox ID
    [Parameter(Mandatory=$true)]
    [string]$mailboxID
  )
  $splitMessage = $message.split('/')
  $exportInfo = $splitMessage[-1]
  $variables = @{
    "workloadFid" = $mailboxID
    "exportUrlSpecsEnc" = $exportInfo
  }
  $query = "query (`$workloadFid: UUID!, `$exportUrlSpecsEnc: String!) {
    decryptExportUrl(workloadFid: `$workloadFid, exportUrlSpecsEnc: `$exportUrlSpecsEnc) {
      blobSasUri
      blobName
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.decryptExportUrl.blobSasUri
}  ### Function Get-DownloadLink


###### FUNCTIONS - END ######

$subscriptions = Get-M365Subscriptions
$subscriptionID = $subscriptions.id

Write-Host "Getting a list of mailboxes..." -foregroundcolor green

$mailboxList = Get-M365Mailboxes -subscriptionID $subscriptionID -mailboxCount $mailboxCount
$mailboxCount = $mailboxList.count

Write-Host "$mailboxCount mailboxes found" -foregroundcolor green
Write-Host ""
$mailboxItem = 1

# For each restore that's initiated, store the event / activity series ID
$taskchainList = @()

$funcGetEmailList = ${function:Get-EmailList}.ToString()

# # Get the root folder ID of each mailbox
# $testUser = $mailboxList | ForEach-Object -throttlelimit $throttleLimit -Parallel {
#   ${function:Get-EmailList} = $using:funcGetEmailList
#   $subscriptionID = $using:subscriptionID
#   Write-Host "$($_.id)"
#   Write-Host "[$mailboxItem / $mailboxCount] Getting emails for user: $($user.userPrincipalName)" -foregroundcolor green
#   $emailList = Get-EmailList -orgID $subscriptionID -mailboxFID $user.id -startDate $startDate
#   Write-Host "[$mailboxItem / $mailboxCount] Found $($emailList.count) emails, initiating export"
#   # $exportPST = Export-EmailsPST -orgID $subscriptionID -mailboxID $user.id -emailList $emailList.node
#   # $taskChainID = $exportPST.data.restoreO365Mailbox.taskChainID
#   # $taskChainItem = [PSCustomObject]@{
#   #   "user" = $user.userPrincipalName
#   #   "userID" = $user.id
#   #   "taskChainID" = $taskChainID
#   # }
#   # $taskchainList += $taskChainItem
#   # $mailboxItem += 1
# }


# # Get the root folder ID of each mailbox
foreach ($user in $mailboxList) {
  Write-Host "[$mailboxItem / $mailboxCount] Getting emails for user: $($user.userPrincipalName)" -foregroundcolor green
  $emailList = Get-EmailList -orgID $subscriptionID -mailboxFID $user.id -startDate $startDate
  Write-Host "[$mailboxItem / $mailboxCount] Found $($emailList.count) emails, initiating export"
  $exportPST = Export-EmailsPST -orgID $subscriptionID -mailboxID $user.id -emailList $emailList.node
  $taskChainID = $exportPST.data.restoreO365Mailbox.taskChainID
  $taskChainItem = [PSCustomObject]@{
    "user" = $user.userPrincipalName
    "userID" = $user.id
    "taskChainID" = $taskChainID
  }
  $taskchainList += $taskChainItem
  $mailboxItem += 1
}

Write-Host ""
Write-Host "PST export initiated for all mailboxes, now waiting for 20 seconds..." -foregroundcolor green
Start-Sleep -Seconds 20
Write-Host "Checking recovery status..." -foregroundcolor green
Write-Host ""

$mailboxItem = 1
foreach ($task in $taskChainList)
{
  Write-Host "[$mailboxItem / $mailboxCount] Lastest activity for: $($task.user)" -foregroundcolor green
  do {
    $eventStatus = Get-EventStatus -taskChainID $task.taskChainID
    if ($eventStatus[0].status -eq 'Running') {
      Write-Host "Recovery is still running for $($task.user), waiting 10 seconds to check again..." -foregroundcolor yellow
      Start-Sleep 10
    } elseif ($eventStatus[0].message -match 'NOT_FOUND') {
      Write-Host "Event not found yet for $($task.user), waiting 10 seconds to check again..." -foregroundcolor yellow
      Start-Sleep 10
    } elseif ($eventStatus[0].status -eq 'Success') {
      Write-Host "Recovery for $($task.user) successful, downloading PST file" -foregroundcolor green
      $eventStatus[0]
      $downloadLink = Get-DownloadLink -message $eventStatus[0].message -mailboxID $task.userID
      $filename = $task.user + "-" + $date.toString("yyyy-MM-dd") + ".pst"
      Invoke-WebRequest -URI $downloadLink -OutFile $filename
    } else {
      Write-Host "Possible error for $($task.user)" -foregroundcolor yellow
      $eventStatus[0]
    }
  } while (($eventStatus[0].status -eq 'Running') -or ($eventStatus[0].message -match 'NOT_FOUND'))
  $mailboxItem += 1
}



# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
