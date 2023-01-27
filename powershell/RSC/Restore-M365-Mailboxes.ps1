<#
.SYNOPSIS
This script will perform a restore of M365 mailboxes for either an email address or specified number of users.

.DESCRIPTION
WARNING - THIS SCRIPT IS STILL A WORK IN PROGRESS AND NEEDS SOME ERROR HANDLING

This script will perform a restore of M365 mailboxes for either an email addres or specified number of users.
Providing an email address will restore all emails that partially match.
Providing a number of users to restore will initiate a mass restore.
If multiple subscriptions are in RSC, you must provide a subscription ID.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/26/23

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Restore-M365Mailboxes.ps1 -emailAddress 'steven'
Restores all email addresses that contains 'steven' in it.

./Restore-M365Mailboxes.ps1 -numMailboxRestore 100
Restore the first 100 mailboxes returned in the list.

./Restore-M365Mailboxes.ps1 -emailAddress 'steven' -subscriptionID '90841-28875-28875'
Specify a subscription ID if there are multiple subscriptions in RSC.
#>


param (
  [CmdletBinding()]
  # M365 Subscription ID
  [Parameter(Mandatory=$false)]
  [string]$subscriptionID,
  # Number of mailboxes to restore
  [Parameter(Mandatory=$false)]
  [int]$numMailboxRestore,
  # Email Address to restore
  [Parameter(Mandatory=$false)]
  [string]$emailAddress
)

$date = Get-Date

# CSV file output
$csvOutput = "./rubrik_m365_restore-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

$retries = 3

# Set to $true to send out email at the end of this script
$sendEmail = $false

###### RUBRIK AUTHENTICATION - BEGIN ######

$serviceAccountPath = "./rsc-service-account-rr.json"

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
  $m365Subscriptions = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.o365Orgs.edges.node
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

# Get details of an email address, all partial matches will be returned
Function Get-M365MailboxDetail {
  param (
    [CmdletBinding()]
    # M365 Subscription ID
    [Parameter(Mandatory=$true)]
    [string]$subscriptionID,
    # Email address
    [Parameter(Mandatory=$true)]
    [string]$emailAddress
  )
  $variables = @{
    "orgId" = $subscriptionID
    "filter" = @(
      @{
        "field" = "NAME_OR_EMAIL_ADDRESS"
        "texts" = @(
          $emailAddress
        )
      },
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "false"
        )
      }
    )
  }
  $query = "query O365MailboxListQuery(`$orgId: UUID!, `$filter: [Filter!]!) {
    o365Mailboxes(o365OrgId: `$orgId, filter: `$filter) {
      edges {
        node {
          id
          ... on O365Mailbox {
            name
            userPrincipalName
            __typename
          }
          __typename
        }
      }
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $mailboxDetail = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.o365Mailboxes.edges.node
  return $mailboxDetail
}  ### Function Get-M365MailboxDetail

# Get most recent index'ed snapshot for a mailbox
Function Get-M365MailboxLatestSnapshot {
  param (
    [CmdletBinding()]
    # Mailbox ID
    [Parameter(Mandatory=$true)]
    [string]$mailboxID
  )
  $variables = @{
    "mailboxId" = $mailboxID
  }
  $query = "query O365MailboxQuery(`$mailboxId: UUID!) {
    o365Mailbox(snappableFid: `$mailboxId) {
      id
      name
      isRelic
      objectType
      userPrincipalName
      newestSnapshot {
        id
        date
        isIndexed
        __typename
      }
      oldestSnapshot {
        date
        id
        isIndexed
        __typename
      }
      newestIndexedSnapshot {
        id
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $mailboxSnapshot = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.o365Mailbox
  return $mailboxSnapshot
}  ### Function Get-M365MailboxLatestSnapshot

# Get the root folder of a snapshot of a mailbox
Function Get-M365MailboxRootFolder {
  param (
    [CmdletBinding()]
    # M365 Subscription ID
    [Parameter(Mandatory=$true)]
    [string]$subscriptionID,
    # Mailbox ID
    [Parameter(Mandatory=$true)]
    [string]$mailboxID,
    # Snapshot ID
    [Parameter(Mandatory=$true)]
    [string]$snapshotID
  )
  # Get the root folder ID for the snapshot being restored
  $variables = @{
    "snapshotFid" = $snapshotID
    "folderId" = "root"
    "snappableFid" = $mailboxID
    "orgId" = $subscriptionID
  }
  $query = "query (`$snapshotFid: UUID!, `$folderId: String!, `$snappableFid: UUID!, `$orgId: UUID!) {
    browseFolder(snapshotFid: `$snapshotFid, folderId: `$folderId, snappableFid: `$snappableFid, orgId: `$orgId) {
      edges {
        node {
          id
          parentFolderId
          ... on O365Folder {
            name
            __typename
          }
          __typename
        }
      }
      count
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $rootFolder = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.browseFolder.edges.node
  $rootFolderID = $rootFolder.id
  return $rootFolder
}  ### Function Get-M365MailboxRootFolder

# Warm the mailbox cache
Function Warm-M365MailboxCache {
  param (
    [CmdletBinding()]
    # Mailbox ID
    [Parameter(Mandatory=$true)]
    [string]$mailboxID
  )
  $variables = @{
    "input" = @{
      "workloadFid" = $mailboxID
    }
  }
  $payload = @{
    "query" = "mutation WarmO365ObjectSearchCacheMutation(`$input: WarmSearchCacheInput!) {
      warmSearchCache(input: `$input)
    }"
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
}  ### Function Warm-M365MailboxCache

# Restore a mailbox to itself
Function Restore-M365Mailbox {
  param (
    [CmdletBinding()]
    # M365 Subscription ID
    [Parameter(Mandatory=$true)]
    [string]$subscriptionID,
    # Mailbox ID
    [Parameter(Mandatory=$true)]
    [string]$mailboxID,
    # Snapshot ID
    [Parameter(Mandatory=$true)]
    [string]$snapshotID,
    # Root Folder ID
    [Parameter(Mandatory=$true)]
    [string]$rootFolderID
  )
  # Restore the root folder of the mailbox to the same user
  $variables = @{
    "mailboxId" = $mailboxID
    "orgId" = $subscriptionID
    "restoreConfigs" = @(
      @{
        "SnapshotUUID" = $snapshotID
        "FolderID" = $rootFolderID
      }
    )
    "actionType" = "RESTORE_SNAPPABLE"
  }
  $payload = @{
    "query" = "mutation (`$orgId: UUID, `$mailboxId: UUID!, `$restoreConfigs: [RestoreObjectConfig!]!, `$actionType: O365RestoreActionType!) {
      restoreO365Mailbox(restoreConfig: {mailboxUuid: `$mailboxId, restoreConfigs: `$restoreConfigs, orgUuid: `$orgId, actionType: `$actionType}) {
        taskchainId
        __typename
      }
    }"
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  $taskchainID = $response.data.restoreO365Mailbox.taskchainId
  return $taskchainID
}  ### Function Restore-M365Mailbox

# Get event series detail
Function Get-EventDetail {
  param (
    [CmdletBinding()]
    # Taskchain ID
    [Parameter(Mandatory=$true)]
    [string]$taskchainID
  )
  $variables = @{
    "activitySeriesId" = $taskchainID
    "clusterUuid" = "00000000-0000-0000-0000-000000000000"
  }
  $query = "query (`$activitySeriesId: UUID!, `$clusterUuid: UUID) {
    activitySeries(input: {activitySeriesId: `$activitySeriesId, clusterUuid: `$clusterUuid}) {
      startTime
      lastUpdated
      progress
      lastActivityType
      lastActivityStatus
      objectId
      objectName
      objectType
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $eventDetail = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  if ($eventDetail.errors) {
    return $eventDetail
  }
  return $eventDetail.data.activitySeries
}  ### Function Get-EventDetail

###### FUNCTIONS - END ######

# Need to provide either an email or number of mailboxes to restore
if ($numMailboxRestore -eq 0 -and ($emailAddress -eq '' -or $emailAddress -eq $null))
{
  Write-Error "An email address or a number of mailboxes to restore must be provided."
}

# If no subscription ID is provided, then get all subscriptions
if ($subscriptionID -eq '' -or $subscriptionID -eq $null)
{
  $subscriptions = Get-M365Subscriptions
  # If more than one subscription is found, user needs to provide one
  if ($subscriptions.count -gt 1) {
    Write-Error "Multiple subscriptions found, please provide an ID"
    $subscriptions | Select-Object -property id, name
    exit
  }
  # If only one subscription is found then set the ID to the subscription
  $subscriptionID = $subscriptions.id
}

Write-Host "Searching for mailboxes..."

# If no email address is given then do a mass restore
if ($emailAddress -eq '' -or $emailAddress -eq $null)
{
  # Get the number of mailboxes specified
  $mailboxes = Get-M365Mailboxes -subscriptionID $subscriptionID -mailboxCount $numMailboxRestore
} else {
  # Get details for the email addresses specified, all partial matches will be returned
  $mailboxes = Get-M365MailboxDetail -subscriptionID $subscriptionID -emailAddress $emailAddress
}

Write-Host "Number of mailboxes found: $($mailboxes.count)" -foregroundcolor green
Write-Host "Getting the latest index'ed snapshot for each mailbox" -foregroundcolor green

# Get the latest index'ed snapshot for each mailbox
foreach ($mailbox in $mailboxes)
{
  $snapshotID = Get-M365MailboxLatestSnapshot -mailboxID $mailbox.id
  if ($snapshotID -eq '' -or $snapshotID -eq $null) {
    Write-Host "No index'ed snapshot found for: $($mailbox.userPrincipalName)"
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'snapshotID' -value 'NoneFound'
  } else {
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'snapshotID' -value $snapshotID
  }
}

Write-Host "Getting the root folder of each mailbox, this may take some time..." -foregroundcolor green

$funcGetM365MailboxRootFolder = ${function:Get-M365MailboxRootFolder}.ToString()
$funcWarmM365MailboxCache = ${function:Warm-M365MailboxCache}.ToString()

# Get the root folder ID of each mailbox
$mailboxes | foreach-object -throttlelimit 16 -parallel {
  if ($_.snapshotID -eq '' -or $_.snapshotID -eq $null -or $_.snapshotID -eq 'NoneFound') {
    Write-Host "No index'ed snapshot found for mailbox, skipping: $($_.userPrincipalName)" -foregroundcolor red
    Add-Member -InputObject $_ -MemberType NoteProperty -name 'rootFolderID' -value ''
  } else {
    Write-Host "Getting root folder for: $($_.userPrincipalName)"
    try {
      ${function:Get-M365MailboxRootFolder} = $using:funcGetM365MailboxRootFolder
      ${function:Warm-M365MailboxCache} = $using:funcWarmM365MailboxCache
      $endpoint = $using:endpoint
      $headers = $using:headers
      Warm-M365MailboxCache -mailboxID $_.id
      Start-Sleep 15
      $retryCount = 1
      $rootFolderID = ''
      do {
        $rootFolderID = Get-M365MailboxRootFolder -subscriptionID $using:subscriptionID -mailboxID $_.id -snapshotID $_.snapshotID
        if ($rootFolderID -eq '' -or $rootFolderID -eq $null) {
          Write-Host "Could not get root folder, retrying ($retryCount of $using:retries) for: $($_.userPrincipalName)" -foregroundcolor yellow
          $retryCount += 1
        } else {
          Write-Host "Got root folder for: $($_.userPrincipalName)"
          Add-Member -InputObject $_ -MemberType NoteProperty -name 'rootFolderID' -value $rootFolderID
        }
      } while (($rootFolderID -eq '' -or $rootFolderID -eq $null) -and $retryCount -le $using:retries)
    } catch {
      Write-Error "Error getting root folder for: $($mailbox.userPrincipalName)"
      Write-Error "$_"
      Add-Member -InputObject $_ -MemberType NoteProperty -name 'rootFolderID' -value 'Error'
    }
    if ($rootFolderID -eq '' -or $rootFolderID -eq $null) {
      Write-Error "Could not get root folder for: $($_.userPrincipalName)"
      Add-Member -InputObject $_ -MemberType NoteProperty -name 'rootFolderID' -value $rootFolderID
    }
  }
}

# Non-parallel loop to get root folder IDs
# foreach ($mailbox in $mailboxes)
# {
#   Write-Host "[$count/$mailboxTotal] Getting root folder for: $($mailbox.userPrincipalName)"
#   try {
#     Write-Host "$subscriptionID $($mailbox.id) $($mailbox.snapshotID)"
#     $rootFolderID = Get-M365MailboxRootFolder -subscriptionID $subscriptionID -mailboxID $mailbox.id -snapshotID $mailbox.snapshotID
#     Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'rootFolderID' -value $rootFolderID
#   } catch {
#     Write-Error "Error getting root folder for: $($mailbox.userPrincipalName)"
#     Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'rootFolderID' -value 'Error'
#   }
#   $count += 1
# }

Write-Host "Initiating restore for each mailbox" -foregroundcolor green
$count = 1
$mailboxTotal = $mailboxes.count

foreach ($mailbox in $mailboxes)
{
  Write-Host "[$count/$mailboxTotal] Initiating restore for: $($mailbox.userPrincipalName)"
  $count += 1
  try {
    $taskChainID = Restore-M365Mailbox -subscriptionID $subscriptionID -mailboxID $mailbox.id -snapshotID $mailbox.snapshotID -rootFolderID $mailbox.rootFolderID
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'taskChainID' -value $taskChainID
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'status' -value 'Active'
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'message' -value ''
  } catch {
    Write-Error "Error trying to restore: $($mailbox.userPrincipalName)"
    Write-Error "$_"
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'taskChainID' -value 'Error'
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'status' -value 'Error'
    Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'message' -value $_
  }
  Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'startTime' -value ''
  Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'endTime' -value ''
  Add-Member -InputObject $mailbox -MemberType NoteProperty -name 'duration' -value ''

}

# Export the list to a CSV file
$mailboxes | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nMailbox and event task ID output to: $csvOutput" -foregroundcolor green


#
# Start-Sleep 20
# Write-Host "Getting event details in a loop"
#
# do {
#   Write-Host "Events still active: $(($mailboxes | Where-Object { $_.status -eq 'Active'}).count)" -foregroundcolor green
#   foreach ($mailbox in ($mailboxes | Where-Object { $_.status -eq 'Active'})) {
#     $eventDetail = $eventDetail = Get-EventDetail -taskChainID $($mailbox.taskChainID)
#     $retryCount = 1
#     do {
#       if ($eventDetail.errors) {
#         $mailbox.status = 'Error'
#         $mailbox.startTime = ''
#         $mailbox.endTime = ''
#         $mailbox.message = $eventDetail.errors.message
#         Write-Host "Error getting event detail for, retrying ($retryCount of $retries): $($mailbox.userPrincipalName)" -foregroundcolor yellow
#         $retryCount += 1
#         Start-Sleep 20
#       } elseif ($eventDetail.lastActivityStatus -eq 'Success' -or $eventDetail.lastActivityStatus -eq 'Failure') {
#         $mailbox.status = $eventDetail.lastActivityStatus
#         $mailbox.startTime = $eventDetail.startTime
#         $mailbox.endTime = $eventDetail.lastUpdated
#         $mailbox.message = $eventDetail.message
#         Write-Host "Restore $($eventDetail.lastActivityStatus) for: $($mailbox.userPrincipalName)" -foregroundcolor green
#       }  #elseif
#     } while ($eventDetail.errors -and $retryCount -le 3)
#   }
#   Start-Sleep 30
# } while ($(($mailboxes | Where-Object { $_.status -eq 'Active'}).count) -gt 0)


# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}
