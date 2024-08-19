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
./Get-OAR-Recoveries.ps1 -operation getEvents
Get all OAR events and export to a CSV.

.EXAMPLE
./Get-OAR-Recoveries.ps1 -operation cleanup
Cleanup all successful Test Failovers.

.EXAMPLE
./Get-OAR-Recoveries.ps1 -operation hydrationEvents -hydrationHours 24 -cluster 'PRD-Cluster'
Get all hydration events for last 24 hours, target the source cluster
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
  # Source cluster for hydration events
  [Parameter(Mandatory=$false)]
  [string]$cluster = 'vault-r-madison'
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output file for OAR Recovery Events
$csvOutputOAR = "./rubrik_oar_events-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# CSV output file for Hydration Status
$csvOutputHydration = "./rubrik-hydration-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# Number of OAR recoveries to get
$oarCount = 250

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
      # Convert the event time to a format that Excel can use
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

if ($operation -eq 'getEvents' -or $operation -eq 'cleanup') {
  Write-Host "Getting the last $oarCount recoveries"
  $oarEvents = Get-OAR-Recoveries -oarCount $oarCount
}

# Get events and export to CSV
if ($operation -eq 'getEvents') {
  Write-Host "Getting and exporting recovery events."
  $oarEventsSelected = $oarEvents | Select-Object jobType, recoveryName, recoveryPlanName, startTime, endTime, durationMin, durationHours, status, blueprintName, blueprintId
  $oarEventsSelected | Export-CSV -Path $csvOutputOAR -NoTypeInformation
  Write-Host "CSV output to: $csvOutputOAR" -foregroundcolor green
}  # getEvents

# Cleanup all blueprints that have test failed over
if ($operation -eq 'cleanup') {
  Write-Host "Cleaning up Test Failovers..." -foregroundcolor green
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

if ($operation -eq 'hydrationStatus') {
  Write-Host "Getting Hydration Status over the last $hydrationHours hours" -foregroundcolor green
  Write-Host "Getting all replicated VMs & snapshots on: $cluster"
  $vms = Get-VMSnapshots -clusterId $clusterID
  $vmList = $vms.edges.node
  while ($vms.pageInfo -eq $true) {
    $vms = Get-VMReplicatedSnapshots -clusterId $clusterID
    $vmList += $vms.edges.node
  }
  # Build a hash table of the VMs for faster processing
  $vmHash = @{}
  foreach ($vm in $vmList) {
    # Only insert protected VMs
    if ($vm.effectiveSlaDomain.name -ne 'UNPROTECTED' -and $vm.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT') {
      $vmHash[$vm.name] = $vm
    }
  }
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
    # Write-Host "[$count / $($hydrationSuccess.count)]"
    # $count++
    # Convert the event time to a format that Excel can use
    $hEventTime = $hEvent.lastUpdated.ToString("yyyy-MM-dd HH:mm:ss")
    # Look at the detailed activity log to get the VM and snapshot that were hydrated
    foreach ($eventDetail in $hEvent.activityConnection.nodes) {
      $eventMatch = [regex]::Match($eventDetail.message, $pattern)
      # If we found a pattern match in the event detail message for the export event
      if ($eventMatch.length -gt 0) {
        $snapshotId = $eventMatch.Groups[1].Value
        $vmName = $eventMatch.Groups[2].Value
        if ($vmHash[$vmName].hydrationTime -eq $null) {
          $vmHash[$vmName] | Add-Member -MemberType NoteProperty -Name 'hydrationTime' -Value $hEventTime
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
      } else {
        # If there wasn't any hydration event for this VM, set things to blank
        $obj | Add-Member -MemberType NoteProperty -Name 'hydrationSnapshotId' -Value ''
        $obj | Add-Member -MemberType NoteProperty -Name 'hydrationTime' -Value ''
        $lastHydratedSnapshot = [PSCustomObject] @{
          "date" = ''
          "id" = ''
        }
      }
      $vmResultList += [PSCustomObject] @{
        "Name" = $obj.name
        "Cluster" = $obj.cluster.name
        "Blueprint Name" = $obj.blueprintName
        "Last Hydration Event Time" = $obj.hydrationTime
        "Last Hydrated Snapshot Time" = $lastHydratedSnapshot.date
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
  $displayResults | Format-Table -AutoSize
  $vmResultList | Export-CSV -Path $csvOutputHydration -NoTypeInformation
  Write-Host "CSV output to: $csvOutputHydration" -foregroundcolor green
}
