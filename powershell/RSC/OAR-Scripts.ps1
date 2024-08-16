# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get OAR DR recoveries and export to a CSV.

.DESCRIPTION
This script will get OAR DR recoveries and export to a CSV.
Times are in EST.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/14/24

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-OAR-Recoveries.ps1 - getEvents
Get all OAR events and export to a CSV.
#>

### Variables section - please fill out as needed


param (
  [CmdletBinding()]
  # Operation to do: getEvents, cleanup
  [Parameter(Mandatory=$false)]
  [string]$operation = '',
  # Recovery Type - not used in the script at the moment
  [Parameter(Mandatory=$false)]
  [string]$recoveryType = ''
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output file
$csvOutput = "./rurik_oar_events-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# Number of OAR recoveries to get
$oarCount = 300

### End Variables section

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    throw "The Service Account JSON secret file was not found. Ensure the file is location at $serviceAccountPath."
  }
  throw $_.Exception
}

Write-Debug -Message "Determing if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($serviceAccountFile.client_id -eq $null -or $serviceAccountFile.client_secret -eq $null -or
      $serviceAccountFile.access_token_uri -eq $null) {
  throw "The Service Account JSON is missing one or more parameters."
}

$headers = @{
  'Content-Type' = 'application/json'
  'Accept' = 'application/json'
}

$payload = @{
  grant_type = "client_credentials"
  client_id = $serviceAccountFile.client_id
  client_secret = $serviceAccountFile.client_secret
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

# Rubrik GraphQL API URLs
$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$endpoint = $rubrikURL + "/api/graphql"
$logoutUrl = $rubrikURL + "/api/session"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept' = 'application/json'
  'Authorization' = $('Bearer ' + $response.access_token)
}

Write-Host "Successfully connected to: $rubrikURL"
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Get all OAR Recoveries
Function Get-OAR-Recoveries {
  param (
    [CmdletBinding()]
    # Number of OAR recoveries to get
    [Parameter(Mandatory=$false)]
    [int]$oarCount = 500
  )
  $variables = @{
    "failoverType" = @(
      "FAILOVER"
      "TEST_FAILOVER"
    )
    "planNames" = @()
    "recoveryNames" = @()
    "recoveryTriggeredFrom" = @()
    "workloadType" = "VSPHERE_VIRTUAL_MACHINE"
    "first" = $oarCount
  }
  $query = "query (`$first: Int, `$failoverType: [FailoverTypeEnum!]!, `$after: String, `$planNames: [String!], `$endTimeMs: DateTime, `$startTimeMs: DateTime, `$workloadIDs: [UUID!], `$recoveryStatus: [RecoveryStatuses!], `$recoveryNames: [String!], `$recoveryTriggeredFrom: [RecoveryTriggeredType!], `$recoveryPlanIds: [UUID!], `$workloadType: ManagedObjectType) {
    failoverJobReports(first: `$first, failoverType: `$failoverType, after: `$after, planNames: `$planNames, endTimeMs: `$endTimeMs, startTimeMs: `$startTimeMs, workloadIDs: `$workloadIDs, RecoveryStatus: `$recoveryStatus, recoveryNames: `$recoveryNames, RecoveryTriggeredFrom: `$recoveryTriggeredFrom, recoveryPlanIds: `$recoveryPlanIds, workloadType: `$workloadType) {
      edges {
        node {
          jobId
          jobType
          status
          startTime
          endTime
          elapsedTime
          progress
          blueprintId
          blueprintName
          objectIds
          recoveryPlanName
          recoveryName
          isBlueprintVisible
          isArchived
          triggeredFrom
          __typename
        }
        cursor
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
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  if ($($result.data).count -gt 0) {
    foreach ($item in $result.data.failoverJobReports.edges.node) {
      $estTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
      $utcStartTime = [System.DateTimeOffset]::FromUnixTimeSeconds($item.startTime).ToUniversalTime()
      $estStartTime = [System.TimeZoneInfo]::ConvertTime($utcStartTime, $estTimeZone)
      $utcEndTime = [System.DateTimeOffset]::FromUnixTimeSeconds($item.endTime).ToUniversalTime()
      $estEndTime = [System.TimeZoneInfo]::ConvertTime($utcEndTime, $estTimeZone)
      $item.startTime = $estStartTime.ToString("yyyy-MM-dd HH:mm:ss")
      $item.endTime = $estEndTime.ToString("yyyy-MM-dd HH:mm:ss")
      $item | Add-Member -MemberType NoteProperty -Name "durationSecs" -Value $item.elapsedTime
      $item | Add-Member -MemberType NoteProperty -Name "durationMin" -Value $([math]::Round($item.durationSecs/60, 2))
      $item | Add-Member -MemberType NoteProperty -Name "durationHours" -Value $([math]::Round($item.durationMin / 60, 2))
    }
  }
  return $result.data.failoverJobReports.edges.node
}  ### Function Get-OAR-Recoveries

# Cleanup Test Failover
Function Cleanup-Failover {
  param (
    [CmdletBinding()]
    # Blueprint ID
    [Parameter(Mandatory=$true)]
    [string]$blueprintID = ''
  )
  $variables = @{
    "jobconfig" = @{
      "blueprintId" = $blueprintID
    }
  }
  $query = "mutation CleanUpDRRecoveriesMutation(`$jobconfig: CleanupFailoverJobInfo!) {
    cleanupBlueprintFailover(cleanupJobconfig: `$jobconfig) {
      jobId
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Cleanup-Failover


###### FUNCTIONS - END ######

Write-Host "Getting the last $oarCount recoveries"
$oarEvents = Get-OAR-Recoveries -oarCount $oarCount

# Get events and expor to CSV
if ($operation -eq 'getEvents') {
  $oarEventsSelected = $oarEvents | Select-Object jobType, recoveryName, recoveryPlanName, startTime, endTime, durationMin, durationHours, status, blueprintName, blueprintId

  $oarEventsSelected | Export-CSV -Path $csvOutput -NoTypeInformation
  Write-Host "CSV output to: $csvOutput" -foregroundcolor green
}  # getEvents

# Cleanup all blueprints that have test failed over
if ($operation -eq 'cleanup') {
  $count = 1
  $testFailovers = $oarEvents | Where { $_.status -eq "Failover succeeded" -And
    $_.jobType -eq 'TestFailover'}
  $tfCount = $testFailovers.count
  Write-Host "Successful test failovers found for cleanpup: $tfCount"
  foreach ($tf in $testFailovers) {
    Write-Host "[$count / $tfCount] Cleaning up: $($tf.recoveryPlanName)"
    $tfResult = Cleanup-Failover -blueprintId $tf.blueprintId
  }
}
