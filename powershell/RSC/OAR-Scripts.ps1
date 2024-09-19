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
./OAR-Scripts.ps1 -operation getEvents
Get all OAR events and export to a CSV.

.EXAMPLE
./OAR-Scripts.ps1 -operation cleanup
Cleanup all successful Test Failovers.

.EXAMPLE
./OAR-Scripts.ps1 -operation cleanup -recoveryEvents 270 -cleanupTimeEST '2024-09-07 16:00' -cleanupLoop $true
Only cleanup test failovers that started after 9/5/24 6pm EST and keep cleaning, and get last 270 events

.EXAMPLE
./OAR-Scripts.ps1 -operation hydrationEvents -hydrationHours 24 -cluster 'PRD-Cluster'
Get all hydration events for last 24 hours, target the source cluster

.EXAMPLE
./OAR-Scripts.ps1 -operation 'deleteScheduled'
Get all blueprint plans and delete any scheduled test failovers

.EXAMPLE
./OAR-Scripts.ps1 -operation 'getRecoveryPlans' -planName 'prod'
Get all recovery plans with 'prod' in the name and latest status

#>

### Variables section - please fill out as needed


param (
  [CmdletBinding()]
  # Operation to do: getEvents, cleanup, hydrationStatus
  [Parameter(Mandatory=$false)]
  [string]$operation = '',
  # Get hydration events for the last x hours
  [Parameter(Mandatory=$false)]
  [int]$hydrationHours = 24,
  # Get recovery events for the last x hours
  [Parameter(Mandatory=$false)]
  [int]$recoveryHours,
  # Source cluster for hydration events
  [Parameter(Mandatory=$false)]
  # [string]$cluster = 'vault-r-madison'
  # [string]$cluster = 'DDC1-RBRK-UAT',
  [string]$cluster = 'HDC2-RBRK-PRD',
  [Parameter(Mandatory=$false)]
  # Number of OAR Recovery events to get
  [int]$recoveryEvents = 25,
  # Set if we want to only cleanup plans after a certain EST time
  # Format: '2024-09-04 18:00' for 6pm EST
  [Parameter(Mandatory=$false)]
  [string]$cleanupTimeEST = '',
  # Set to true to loop through the cleanup
  [Parameter(Mandatory=$false)]
  [bool]$cleanupLoop = $false,
  # For getRecoveryPlans, filter by a specific plan name
  [Parameter(Mandatory=$false)]
  [string]$planName = ''
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output file for OAR Recovery Events
$csvOutputOAR = "./rubrik_oar_events-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# CSV output file for per-VM level Hydration Status
$csvOutputHydrationVM = "./rubrik-hydration_vm-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# CSV output file for per-blueprint level Hydration Status
$csvOutputHydrationBlueprint = "./rubrik-hydration_blueprint-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

$csvOutputRecoveryPlans = "./rubrik-recovery_plans-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

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


# Get Cluster list
Function Get-ClusterList {
  param (
    [CmdletBinding()]
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$clusterUUID = ''
  )
  $variables = @{
    "sortBy" = "ClusterName"
    "sortOrder" = "ASC"
    "filter" = @{
      "id" = @()
      "name" = @(
        ""
      )
      "type" = @()
      "systemStatus" = @()
      "productType" = @(
        "CDM"
      )
    }
    "first" = 50
  }
  $query = "query AllClusterListTableQuery(`$first: Int, `$after: String, `$filter: ClusterFilterInput, `$sortBy: ClusterSortByEnum, `$sortOrder: SortOrder) {
    allClusterConnection(
      filter: `$filter
      sortBy: `$sortBy
      sortOrder: `$sortOrder
      first: `$first
      after: `$after
    ) {
      edges {
        cursor
        node {
          id
          name
          pauseStatus
          geoLocation {
            address
          }
          status
          systemStatus
          clusterNodeConnection {
            count
            nodes {
              id
              status
              ipAddress
            }
          }
          lastConnectionTime
          state {
            connectedState
            clusterRemovalState
          }
          version
          productType
          type
          metric {
            usedCapacity
            availableCapacity
            totalCapacity
          }
        }
      }
      pageInfo {
        startCursor
        endCursor
        hasNextPage
        hasPreviousPage
      }
      count
    }
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $clusterList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $clusterList.data.allClusterConnection.edges.node
}  ### Function ClusterList


# Get all OAR Recoveries
Function Get-OAR-Recoveries {
  param (
    [CmdletBinding()]
    # Number of OAR recoveries to get
    [Parameter(Mandatory=$true)]
    [int]$recoveryEvents,
    # How many hours back to
    [Parameter(Mandatory=$false)]
    [int]$recoveryHours,
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
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
    "first" = $recoveryEvents
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  if ($recoveryHours -ne '') {
    $startTimeMs = $utcDate.AddHours(-$hydrationHours)
    $startTimeMs = $startTimeMs.toString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $variables.startTimeMs = $
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
      # Convert the event time to a format that Excel can use
      $item.startTime = $estStartTime.ToString("yyyy-MM-dd HH:mm:ss")
      $item.endTime = $estEndTime.ToString("yyyy-MM-dd HH:mm:ss")
      $item | Add-Member -MemberType NoteProperty -Name "vmCount" -Value $item.objectIds.count
      $item | Add-Member -MemberType NoteProperty -Name "durationSecs" -Value $item.elapsedTime
      $item | Add-Member -MemberType NoteProperty -Name "durationMin" -Value $([math]::Round($item.durationSecs/60, 2))
      $item | Add-Member -MemberType NoteProperty -Name "durationHours" -Value $([math]::Round($item.durationMin / 60, 2))
    }
  }
  return $result.data.failoverJobReports
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


# Delete scheduled test failover
Function Delete-Schedule {
  param (
    [CmdletBinding()]
    # Blueprint ID
    [Parameter(Mandatory=$true)]
    [string]$blueprintID = ''
  )
  $variables = @{
    "input" = @{
      "recoveryPlanFid" = $blueprintID
    }
  }
  $query = "mutation DeleteRecoverySchedule(`$input: DeleteRecoveryScheduleInput!) {
    deleteRecoverySchedule(input: `$input)
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Delete-Schedule


# Get VM list and snapshots for each VM
Function Get-VMSnapshots {
  param (
    [CmdletBinding()]
    # Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$clusterID = '',
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "first" = 1000
    "filter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "false"
        )
      }
      @{
        "field" = "IS_REPLICATED"
        "texts" = @(
          "false"
        )
      }
      @{
        "field" = "IS_ACTIVE"
        "texts" = @(
          "true"
        )
      }
      @{
        "field" = "NAME"
        "texts" = @(
          ""
        )
      }
      @{
        "field" = "CLUSTER_ID"
        "texts" = @(
          "$clusterID"
        )
      }
      @{
        "field" = "IS_ACTIVE_AMONG_DUPLICATED_OBJECTS"
        "texts" = @(
          "false"
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query (`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereVmNewConnection(
      filter: `$filter
      first: `$first
      after: `$after
      sortBy: `$sortBy
      sortOrder: `$sortOrder
    ) {
      edges {
        cursor
        node {
          id
          cdmId
          name
          objectType
          blueprintName
          blueprintId
          newestSnapshot {
            id
          }
          snapshotConnection {
            edges {
              node {
                id
                date
                cdmId
                cluster {
                  name
                  id
                }
                snappableId
              }
            }
          }
          ... on CdmHierarchyObject {
            replicatedObjectCount
            cluster {
              id
              name
              version
              status
              __typename
            }
          }
          ... on HierarchyObject {
            id
            effectiveSlaDomain {
              id
              name
              ... on GlobalSlaReply {
                isRetentionLockedSla
                retentionLockMode
                __typename
              }
              ... on ClusterSlaDomain {
                fid
                cluster {
                  id
                  name
                  __typename
                }
                isRetentionLockedSla
                retentionLockMode
                __typename
              }
              __typename
              ... on GlobalSlaReply {
                description
                __typename
              }
            }
            __typename
          }
          ... on HierarchyObject {
            effectiveSlaSourceObject {
              fid
              name
              objectType
              __typename
            }
            slaAssignment
            __typename
          }
          isRelic
          templateType
          primaryClusterLocation {
            id
            name
            __typename
          }
          slaPauseStatus
          snapshotDistribution {
            id
            totalCount
            __typename
          }
          vmwareToolsInstalled
          agentStatus {
            agentStatus
            __typename
          }
        }
        __typename
      }
      pageInfo {
        startCursor
        endCursor
        hasNextPage
        hasPreviousPage
        __typename
      }
      count
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.vSphereVmNewConnection
}  ### Function Get-VMSnapshots


# Get the recovery plans
Function Get-RecoveryPlans {
  param (
    [CmdletBinding()]
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "filter" = @(
      @{
        "field" = "NAME"
        "texts" = @(
          ""
        )
      }
      @{
        "field" = "RECOVERY_PLAN_TYPE"
        "texts" = @(
          "DISASTER_RECOVERY"
        )
      }
      @{
        "field" = "IS_RECOVERY_PLAN_VISIBLE"
        "texts" = @(
          "1"
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "first" = 50
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query RecoveryPlansQuery(`$first: Int, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]) {
    recoveryPlans(
      first: `$first
      after: `$after
      sortBy: `$sortBy
      sortOrder: `$sortOrder
      filter: `$filter
    ) {
      edges {
        cursor
        node {
          id
          status
          version
          ... on RecoveryPlan {
            id
            name
            isHydrationEnabled
            __typename
          }
          ... on RecoveryPlan {
            numChildren
            __typename
          }
          ... on RecoveryPlan {
            sourceLocation {
              ... on BlueprintCdmLocation {
                cluster {
                  name
                  id
                  status
                  version
                  __typename
                }
              }
            }
          }
          ... on RecoveryPlan {
            targetLocation {
              ... on BlueprintCdmLocation {
                cluster {
                  name
                  id
                  status
                  version
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
          latestFailover {
            status
            failoverType
            __typename
          }
          recoveryType
          recoveryCount {
            failoverRecoveryCount
            isolatedRecoveryCount
            localRecoveryCount
            testFailoverRecoveryCount
            __typename
          }
          schedule {
            scheduleId
            __typename
          }
          isVisible
          lastIsolatedRecoveryStatus
          lastIsolatedRecoveryTime
          lastFailoverStatus
          lastFailoverTime
          lastTestFailoverStatus
          lastTestFailoverTime
          lastLocalRecoveryStatus
          lastLocalRecoveryTime
          __typename
        }
        __typename
      }
      pageInfo {
        endCursor
        hasNextPage
        hasPreviousPage
      }
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.recoveryPlans
}  ### Function Get-RecoveryPlans


# Get hydration events and status
Function Get-HydrationStatus {
  param (
    [CmdletBinding()]
    # Get hydration events for last x hours
    [Parameter(Mandatory=$false)]
    [int]$hydrationHours = 24,
    [CmdletBinding()]
    # Page cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = $null
  )
  $lastUpdatedTimeGt = $utcDate.AddHours(-$hydrationHours)
  $lastUpdatedTimeGt = $lastUpdatedTimeGt.toString("yyyy-MM-ddTHH:mm:ss.fffZ")
  $variables = @{
    "filters" = @{
      "objectType" = 'VMWARE_VM'
      "lastActivityStatus" = $null
      "lastActivityType" = @(
        "RECOVERY"
      )
      "severity" = $null
      "clusterId" = $null
      "lastUpdatedTimeGt" = $lastUpdatedTimeGt
      "orgIds" = @()
      "userIds" = $null
      "objectName" = $null
    }
    "first" = 100
    "after" = $cursor
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query EventSeriesListQuery(`$after: String, `$filters: ActivitySeriesFilter, `$first: Int, `$sortBy: ActivitySeriesSortField, `$sortOrder: SortOrder) {
    activitySeriesConnection(
      after: `$after
      first: `$first
      filters: `$filters
      sortBy: `$sortBy
      sortOrder: `$sortOrder
    ) {
      edges {
        cursor
        node {
          id
          fid
          activitySeriesId
          lastUpdated
          lastActivityType
          lastActivityStatus
          objectId
          objectName
          objectType
          severity
          progress
          location
          effectiveThroughput
          dataTransferred
          logicalSize
          clusterUuid
          clusterName
          activityConnection(first: 500) {
            nodes {
              id
              message
              __typename
            }
            __typename
          }
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
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.activitySeriesConnection
}  ### Function Get-HydrationStatus



###### FUNCTIONS - END ######

$clusters = Get-ClusterList
$clusterID = $($clusters | Where { $_.name -eq $cluster }).id


if ($operation -eq 'getEvents') {
  Write-Host "Getting the lastest $recoveryEvents recovery events..."
  Write-Host 'If you want to grab more recovery events, use "-recoveryEvents <count>"'
  # Holds array of OAR events that we are grabbing
  $oarEvents = @()
  $count = 0
  $hasNextPage = $true
  $afterCursor = ''
  # Get up to 50 OAR events at a time to avoid timeout
  while ( ($count -lt $recoveryEvents) -and ($hasNextPage -eq $true) ) {
    if ($recoveryEvents -gt 50) {
      Write-Host "Grabbing events $($count + 1) - $($count + 50)..."
    } else {
      Write-Host "Grabbing events $count - $($($count + 1) + $recoveryEvents)..."
    }
    if ( ($recoveryEvents - $count) -lt 50) {
      $eventsToGet = $recoveryEvents - $count
      $count += $eventsToGet
    } else {
      $eventsToGet = 50
      $count += 50
    }
    $oar = Get-OAR-Recoveries -recoveryEvents $eventsToGet -afterCursor $afterCursor
    $oarEvents += $oar.edges.node
    $hasNextPage = $oar.pageInfo.hasNextPage
    $afterCursor = $oar.pageInfo.endCursor
  }
}

# Get events and export to CSV
if ($operation -eq 'getEvents') {
  if ($oarEvents.count -gt 25) {
    Write-Host "Displaying the latest 25 recovery events to console"
  }
  $displayResults = $oarEvents | Select-Object -First 25 -Property 'recoveryName',
    'recoveryPlanName', 'startTime', 'endTime', 'vmCount', 'durationMin', 'durationHours', 'status', 'progress', 'jobType'
  $displayResults | Format-Table -AutoSize
  $oarEventsSelected = $oarEvents | Select-Object recoveryName, recoveryPlanName, startTime, endTime, vmCount, durationMin, durationHours, status, jobType, progress, blueprintName, blueprintId
  $oarEventsSelected | Export-CSV -Path $csvOutputOAR -NoTypeInformation
  $uniqueStatuses = @()
  $uniqueStatuses += $oarEventsSelected | Select-Object -Property 'Status' -Unique -ExpandProperty 'Status'
  foreach ($status in $uniqueStatuses) {
    $statusCount = $($oarEventsSelected | Where { $_.status -like $status }).count
    Write-Host "$($status): $statusCount" -foregroundcolor green
  }
  Write-Host ""
  Write-Host "Total number of failover events found: $($oarEventsSelected.count)" -foregroundcolor green
  Write-Host ""
  Write-Host "CSV output to: $csvOutputOAR" -foregroundcolor green
}  # getEvents

# Cleanup all blueprints that have test failed over
if ($operation -eq 'cleanup') {
  $loop = $true
  while ($loop) {
    # copy / paste
    Write-Host "Getting the lastest $recoveryEvents recovery events..."
    Write-Host 'If you want to grab more recovery events, use "-recoveryEvents <count>"'
    # Holds array of OAR events that we are grabbing
    $oarEvents = @()
    $count = 0
    $hasNextPage = $true
    $afterCursor = ''
    # Get up to 50 OAR events at a time to avoid timeout
    while ( ($count -lt $recoveryEvents) -and ($hasNextPage -eq $true) ) {
      if ($recoveryEvents -gt 50) {
        Write-Host "Grabbing events $($count + 1) - $($count + 50)..."
      } else {
        Write-Host "Grabbing events $count - $($($count + 1) + $recoveryEvents)..."
      }
      if ( ($recoveryEvents - $count) -lt 50) {
        $eventsToGet = $recoveryEvents - $count
        $count += $eventsToGet
      } else {
        $eventsToGet = 50
        $count += 50
      }
      $oar = Get-OAR-Recoveries -recoveryEvents $eventsToGet -afterCursor $afterCursor
      $oarEvents += $oar.edges.node
      $hasNextPage = $oar.pageInfo.hasNextPage
      $afterCursor = $oar.pageInfo.endCursor
    }
    # end copy / paste
    $loop = $cleanupLoop
    Write-Host "Cleaning up Test Failovers..." -foregroundcolor green
    # Get list of Test Failovers that are ready to cleanup
    $testFailovers = $oarEvents | Where { $_.status -eq "Failover succeeded" -And
      $_.jobType -eq 'TestFailover'}
    # Cleanup list
    $cleanupList = @()
    # If time is provided, only cleanup plans after this time
    if ($cleanupTimeEST -ne '') {
      $cleanupTimeESTdt = [datetime]::ParseExact($cleanupTimeEST, 'yyyy-MM-dd HH:mm', $null)
      foreach ($tf in $testFailovers) {
        $startTimeDT = [datetime]::ParseExact($($tf.startTime), 'yyyy-MM-dd HH:mm:ss', $null)
        if ($startTimeDT -gt $cleanupTimeESTdt) {
          $cleanupList += $tf
        }
      }
    } else {
      $cleanupList = $testFailovers
    }
    $tfCount = $testFailovers.count
    $count = 1
    Write-Host "Successful test failovers found for cleanpup: $tfCount"
    foreach ($tf in $cleanupList) {
      Write-Host "[$count / $tfCount] Cleaning up: $($tf.recoveryPlanName)"
      $count++
      $tfResult = Cleanup-Failover -blueprintId $tf.blueprintId
    }
  Write-Host "Waiting 120 seconds..."
  Start-Sleep 120
  }
}

if ($operation -eq 'hydrationStatus') {
  Write-Host "Getting Hydration Status over the last $hydrationHours hours" -foregroundcolor green
  Write-Host "Getting all VMs & snapshots on: $cluster, this can take a few minutes..."
  $vms = Get-VMSnapshots -clusterId $clusterID
  $vmList = $vms.edges.node
  while ($vms.pageInfo.hasNextPage -eq $true) {
    $vms = Get-VMSnapshots -clusterId $clusterID -afterCursor $vms.pageInfo.endCursor
    $vmList += $vms.edges.node
  }
  Write-Host "Found $($vmCount) VMs..."
  Write-Host "Building hash table of VMs that have a SLA assigned..."
  # Build a hash table of the VMs for faster processing
  $vmHash = @{}
  foreach ($vm in $vmList) {
    # Only insert protected VMs
    if ($vm.effectiveSlaDomain.name -ne 'UNPROTECTED' -and $vm.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT') {
      $vmHash[$vm.name] = $vm
    }
  }
  Write-Host "Found $($vmHash.count) VMs currently being PROTECTED..."
  Write-Host "Getting Hydration Events over the last $hydrationHours hours..."
  # Get all hydration events over the last x hours
  $hydrations = Get-HydrationStatus -hydrationHours $hydrationHours
  $hydrationEvents = $hydrations.edges.node
  while ($hydrations.pageInfo.hasNextPage -eq $true) {
    $hydrations = Get-HydrationStatus -hydrationHours $hydrationHours -afterCursor $hydrations.pageInfo.endCursor
    $hydrationEvents += $hydrations.edges.node
  }
  $hydrationRunning = $hydrationEvents | Where { $_.lastActivityStatus -match 'Running' }
  $hydrationSuccess = $hydrationEvents | Where { $_.lastActivityStatus -match 'Success' }
  $hydrationFailed = $hydrationEvents | Where { $_.lastActivityStatus -match 'Fail' }
  Write-Host "Successful hydration events: $($hydrationSuccess.count)"
  Write-Host "In Progress hydration events: $($hydrationRunning.count)"
  Write-Host "Failed hydration events: $($hydrationFailed.count)"
  # Get the per VM details of each successful hydration event
  $pattern = "Export of snapshot '([a-f0-9-]+)' from vSphere VM '([^']+)' succeeded"
  $count = 1
  foreach ($hEvent in $hydrationSuccess) {
    # Convert the event time to a format that Excel can use
    $hEventTime = $hEvent.lastUpdated.ToString("yyyy-MM-dd HH:mm:ss")
    # Look at the detailed activity log to get the VM and snapshot that were hydrated
    foreach ($eventDetail in $hEvent.activityConnection.nodes) {
      $eventMatch = [regex]::Match($eventDetail.message, $pattern)
      # If we found a pattern match in the event detail message for the export event
      if ($eventMatch.length -gt 0) {
        $snapshotId = $eventMatch.Groups[1].Value
        $vmName = $eventMatch.Groups[2].Value
        if ($vmHash[$vmName].hydrationEventTime -eq $null -and $vmHash.containsKey($vmName)) {
          $vmHash[$vmName] | Add-Member -MemberType NoteProperty -Name 'hydrationEventTime' -Value $hEventTime
          $vmHash[$vmName] | Add-Member -MemberType NoteProperty -Name 'hydrationSnapshotId' -Value $snapshotId
        }
      }
    }
  }  ## For loop through each hydration success event
  # Process VM hash table to pull out the properties we want to export to CSV
  $vmResultList = @()
  foreach ($key in $vmHash.keys) {
    $obj = $vmHash[$key]
    # If VM is in a blueprint, then add to the list and check hydration
    if ($obj.blueprintName.count -gt 0) {
      # Get the most recent snapshot for the VM
      if ($obj.snapshotConnection.edges.count -gt 0) {
        $latestSnapshot = $obj.snapshotConnection.edges.node[-1]
        $latestSnapshot.date = $latestSnapshot.date.ToString("yyyy-MM-dd HH:mm:ss")
      } else {
        # If no snapshot found
        $latestSnapshot = [PSCustomObject] @{
          "date" = ''
          "id" = ''
          "cdmId" = ''
        }
      }
      # Find the details of the last snapshot that was hydrated
      if ($obj.hydrationSnapshotId.count -gt 0) {
        $lastHydratedSnapshot = $obj.snapshotConnection.edges.node | Where { $_.cdmid -eq $obj.hydrationSnapshotId }
        if ($($lastHydratedSnapshot.date.gettype().name) -eq 'DateTime') {
          $lastHydratedSnapshotTime = $lastHydratedSnapshot.date.ToString("yyyy-MM-dd HH:mm:ss")
        }
      } else {
        # If there wasn't any hydration event for this VM, set things to blank
        $obj | Add-Member -MemberType NoteProperty -Name 'hydrationSnapshotId' -Value ''
        $obj | Add-Member -MemberType NoteProperty -Name 'hydrationEventTime' -Value ''
        $lastHydratedSnapshotTime = ''
      }
      $vmResultList += [PSCustomObject] @{
        "Name" = $obj.name
        "Cluster" = $obj.cluster.name
        "Blueprint Name" = $obj.blueprintName
        "Last Hydration Event Time" = $obj.hydrationEventTime
        "Last Hydrated Snapshot Time" = $lastHydratedSnapshotTime
        "Most Recent Snapshot Time" = $latestSnapshot.date
        "VM ID" = $obj.id
        "VM CDM ID" = $obj.cdmId
        "Blueprint ID" = $obj.blueprintId
        "Last Hydrated Snapshot ID" = $obj.hydrationSnapshotId
        "Most Recent Snapshot ID" = $latestSnapshot.id
        "Most Recent Snapshot CDM ID" = $latestSnapshot.cdmId
      }
    }
  }  ## For loop through each VM to add results to $vmResultList
  $vmResultList = $vmResultList | Sort-Object -Property 'Blueprint Name', 'Last Hydrated Snapshot Time'
  $displayResults = $vmResultList | Select-Object -First 25 -Property 'Name',
    'Cluster', 'Blueprint Name', 'Last Hydration Event Time', 'Last Hydrated Snapshot Time',
    'Most Recent Snapshot Time'
    Write-Host "Displaying first 25 VMs, rest will be in a CSV"
  $displayResults | Format-Table -AutoSize
  $vmResultList | Export-CSV -Path $csvOutputHydrationVM -NoTypeInformation
  Write-Host ""
  $blueprintList = @()
  # Group the results by blueprint
  $groupedData = $vmResultList | Group-Object -Property "Blueprint Name"
  # Loop through each blueprint, and parse the 'Last Hydrated Snapshot Time'
  foreach ($group in $groupedData) {
      $snapshotTimes = $group.group.'Last Hydrated Snapshot Time' | sort-Object
      # If blueprint contains multiple VMs, get the oldest and latest snapshot
      if ($snapshotTimes.count -gt 1) {
        $oldestSnapshotTime = $snapshotTimes[0]
        $latestSnapshotTime = $snapshotTimes[-1]
      } else {
        # If blueprint only contains a single VM, set oldest and latest together
        $oldestSnapshotTime = $snapshotTimes
        $latestSnapshotTime = $snapshotTimes
      }
    # Create a new PSCustomObject with the required fields
    $blueprintDetail = [PSCustomObject]@{
        "Blueprint Name" = $group.Name
        "# of VMs" = $group.Count
        "Latest Hydrated Snapshot Time" = $latestSnapshotTime
        "Oldest Hydrated Snapshot Time" = $oldestSnapshotTime
    }
    # Add the result to the results array
    $blueprintList += $blueprintDetail
  }
  Write-Host ""
  $blueprintList = $blueprintList | sort-object -property 'Oldest Hydrated Snapshot Time' -Descending
  $blueprintList
  $blueprintList | Export-Csv -Path $csvOutputHydrationBlueprint -NoTypeInformation
  Start-sleep 5
  Write-Host "VM-level CSV output to: $csvOutputHydrationVM" -foregroundcolor green
  Write-Host "Blueprint-level CSV output to: $csvOutputHydrationBlueprint" -foregroundcolor green
  Write-Host "Scroll up to see per-VM and per-Blueprint info" -foregroundcolor green
}  ## IF $operation -eq 'hydrationStatus'

# Go through all blueprints and get all recovery plans
if ($operation -eq 'deleteScheduled' -or $operation -eq 'getRecoveryPlans') {
  Write-Host "Getting all Recovery Plans"
  $plansList = @()
  $plans = $null
  $hasNextPage = $true
  while ($hasNextPage -eq $true) {
    $plans = Get-RecoveryPlans -afterCursor $plans.pageInfo.endCursor
    $plansList += $plans.edges.node
    $hasNextPage = $plans.pageInfo.hasNextPage
  }
  Write-Host "Total plans found: $($plansList.count)" -foregroundcolor green
}

if ($operation -eq 'getRecoveryPlans') {
  if ($planName -ne '') {
    $plansList = $plansList | Where { $_.Name -match $planName }
    Write-Host "Plans found containing the word ${planName}: $($plansList.count)" -foregroundcolor green
  }
  if ($plansList.count -gt 0) {
    $displayPlans = $plansList | Select-Object -Property Name, @{
        Expression = { $_.latestFailover.status }
    }, lastTestFailoverTime, isHydrationEnabled | Sort-Object lastTestFailoverTime -Descending
  }
  $displayPlans | Format-table
  Write-Host "Exporting to: $csvOutputRecoveryPlans" -foregroundcolor green
  $displayPlans | Export-CSV -Path $csvOutputRecoveryPlans -NoTypeInformation
}

# Delete any scheduling on the recovery plans found
if ($operation -eq 'deleteScheduled') {
  Write-Host "Remove any scheduled recoveries for the plans."
  $count = 0
  foreach ($bp in $plansList) {
    if ($bp.schedule.scheduleId -gt 0) {
      $result = Delete-Schedule -blueprintID $bp.id
      $count++
    }
  }
  Write-Host "Deleted schedules for $count plans."
} ## IF $operation -eq 'deleteScheduled'


# Log out of RSC session
$closeStatus = $(Invoke-RestMethod -Method DELETE -Uri $logoutUrl -Headers $headers -ContentType "application/json")
