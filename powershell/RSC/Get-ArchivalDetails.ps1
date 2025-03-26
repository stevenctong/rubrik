# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get the archival details for VMware and SQL objects.

.DESCRIPTION
This script will get the archival details for VMware and SQL objects.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/1/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-ArchivalDetails.ps1
Runs the script.
#>

### Variables section - please fill out as needed

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV file info
$csvOutput = "./rubrik_archival_details-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# CSV to output file of objects without a recent archival to the 2nd location
# since the end of the prior month
$csvOutput2 = "./rubrik_archival_2nd_missing-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik - " + $date.ToString("yyyy-MM-dd HH:MM")

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

# Get VM list
Function Get-VMList {
  param (
    [CmdletBinding()]
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
      },
      @{
        "field" = "IS_REPLICATED"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_ACTIVE"
        "texts" = @(
          "true"
        )
      },
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
  $query = "query VSphereVMsListQuery(`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
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
        snapshotConnection {
          edges {
            node {
              id
              date
              archivalLocations {
                id
                name
              }
            }
          }
        }
        snapshotConsistencyMandate
        snapshotConsistencySource
        ... on HierarchyObject {
          id
          name
          objectType
          __typename
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
          __typename
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
          ... on CdmHierarchyObject {
            pendingSla {
              id
              name
              ... on ClusterSlaDomain {
                fid
                cluster {
                  id
                  name
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
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
        ... on HierarchyObject {
          allOrgs {
            fullName
            __typename
          }
          __typename
        }
        isRelic
        templateType
        primaryClusterLocation {
          id
          name
          __typename
        }
        logicalPath {
          fid
          name
          objectType
          __typename
        }
        physicalPath {
          fid
          name
          objectType
          __typename
        }
        slaPauseStatus
        snapshotDistribution {
          id
          totalCount
          __typename
        }
        reportWorkload {
          id
          archiveStorage
          physicalBytes
          __typename
        }
        vmwareToolsInstalled
        agentStatus {
          agentStatus
          __typename
        }
        vsphereVirtualDisks {
          edges {
            node {
              fid
              datastoreFid
              fileName
              size
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
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
}  ### Function Get-VMList


# Get SQL DB list
Function Get-SQLList {
  param (
    [CmdletBinding()]
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
      },
      @{
        "field" = "IS_REPLICATED"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_LOG_SHIPPING_SECONDARY"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_MOUNT"
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
  $query = "query MssqlDatabaseListQuery(`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
  mssqlDatabases(
    filter: `$filter
    first: `$first
    after: `$after
    sortBy: `$sortBy
    sortOrder: `$sortOrder
  ) {
    edges {
      cursor
      node {
        name
        id
        cdmId
        dagId
        snapshotConnection {
          edges {
            node {
              id
              date
              archivalLocations {
                id
                name
              }
            }
          }
        }
        unprotectableReasons
        isInAvailabilityGroup
        __typename
        logBackupFrequencyInSeconds
        cluster {
          id
          status
          __typename
        }
        replicas {
          recoveryModel
          __typename
          state
        }
        effectiveSlaDomain {
          id
          name
          ... on GlobalSlaReply {
            objectSpecificConfigs {
              mssqlConfig {
                frequency {
                  duration
                  unit
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
        }
        copyOnly
        ... on CdmHierarchyObject {
          replicatedObjectCount
          cluster {
            id
            name
            version
            status
            __typename
          }
          __typename
        }
        ... on HierarchyObject {
          allOrgs {
            fullName
            __typename
          }
          __typename
        }
        ... on CdmHierarchyObject {
          cluster {
            id
            name
            version
            __typename
          }
          primaryClusterLocation {
            id
            __typename
          }
          __typename
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
          ... on CdmHierarchyObject {
            pendingSla {
              id
              name
              ... on ClusterSlaDomain {
                fid
                cluster {
                  id
                  name
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
        }
        logicalPath {
          name
          objectType
          __typename
        }
        physicalPath {
          name
          objectType
          __typename
        }
        ... on HierarchyObject {
          name
          __typename
        }
        ... on HierarchyObject {
          slaAssignment
          effectiveSlaSourceObject {
            fid
            name
            objectType
            __typename
          }
          __typename
        }
        ... on HierarchyObject {
          numWorkloadDescendants
          objectType
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
    __typename
  }
}"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.mssqlDatabases
}  ### Function Get-SQLList

# Get Backup Details
Function Get-BackupDetail {
  param (
    [CmdletBinding()]
    # ID of object to query - for SQL it might be dagID
    [Parameter(Mandatory=$false)]
    [string]$objId = ''
  )
  $variables = @{
    "snappableId" = $objId
    "first" = 50
    "sortBy" = "CREATION_TIME"
    "sortOrder" = "DESC"
    "snapshotFilter" = @(
      @{
        "field" = "SNAPSHOT_TYPE"
        "typeFilters" = @()
      }
    )
    "timeRange" = $null
  }
  $query = "query SnapshotsListSingleQuery(`$snappableId: String!, `$first: Int, `$after: String, `$snapshotFilter: [SnapshotQueryFilterInput!], `$sortBy: SnapshotQuerySortByField, `$sortOrder: SortOrder, `$timeRange: TimeRangeInput) {
  snapshotsListConnection: snapshotOfASnappableConnection(
    workloadId: `$snappableId
    first: `$first
    after: `$after
    snapshotFilter: `$snapshotFilter
    sortBy: `$sortBy
    sortOrder: `$sortOrder
    timeRange: `$timeRange
  ) {
    edges {
      cursor
      node {
        ... on CdmSnapshot {
          latestUserNote {
            time
            userName
            userNote
            __typename
          }
          __typename
        }
        id
        date
        expirationDate
        isOnDemandSnapshot
        ... on CdmSnapshot {
          cdmVersion
          isRetentionLocked
          isDownloadedSnapshot
          cluster {
            id
            name
            version
            status
            timezone
            __typename
          }
          pendingSnapshotDeletion {
            id: snapshotFid
            status
            __typename
          }
          slaDomain {
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
          }
          pendingSla {
            id
            name
            ... on ClusterSlaDomain {
              fid
              cluster {
                id
                name
                __typename
              }
              __typename
            }
            __typename
          }
          snapshotRetentionInfo {
            isCustomRetentionApplied
            archivalInfos {
              name
              isExpirationDateCalculated
              expirationTime
              locationId
              __typename
            }
            localInfo {
              name
              isExpirationDateCalculated
              expirationTime
              __typename
            }
            replicationInfos {
              name
              isExpirationDateCalculated
              expirationTime
              locationId
              isExpirationInformationUnavailable
              __typename
            }
            __typename
          }
          legalHoldInfo {
            shouldHoldInPlace
            __typename
          }
          __typename
        }
        ... on PolarisSnapshot {
          isDeletedFromSource
          isDownloadedSnapshot
          isReplica
          isArchivalCopy
          slaDomain {
            name
            id
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
            ... on ClusterSlaDomain {
              fid
              cluster {
                id
                name
                __typename
              }
              __typename
            }
            ... on GlobalSlaReply {
              id
              __typename
            }
          }
          __typename
        }
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
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
  return $result.data.snapshotsListConnection.edges.node
}  ### Function Get-BackupDetail

###### FUNCTIONS - END ######

# Holds list of objects and if they have backups that were archived or not
$objList = @()

Write-Host "Getting a list of all VMs"
$vmList = @()
$afterCursor = ''
do {
  $vmInventory = Get-VMList -afterCursor $afterCursor
  $vmList += $vmInventory.edges.node
  $afterCursor = $vmInventory.pageInfo.endCursor
} while ($vmInventory.pageInfo.hasNextPage)

# Filter list by protected VMs
$protectedVMs = $vmList | Where { $_.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

Write-Host "Found $($vmList.count) protected VMs" -foregroundcolor green

Write-Host "Processing VMs..."

# Go through each protected VM and find the last backup that was archived
# to a single location and to two archive locations.
foreach ($vm in $protectedVMs) {
  $backups = $vm.snapshotConnection.edges.node | sort-object "Date" -descending
  if ($backups.count -gt 0) {
    $latestBackup = $backups[0].date
    $archiveOne = $backups | Where { $_.archivalLocations.count -ge 1 }
    if ($archiveOne.count -gt 0) {
      $latestOneArchive = $archiveOne[0].date
    } else {
      $latestOneArchive = ''
    }
    $archiveTwo = $backups | Where { $_.archivalLocations.count -ge 2 }
    if ($archiveTwo.count -gt 0) {
      $latestTwoArchive = $archiveTwo[0].date
    } else {
      $latestTwoArchive = ''
    }
  } else {
    $latestBackup = ''
    $latestOneArchive = ''
    $latestTwoArchive = ''
  }
  $vmSLA = $vm.effectivesladomain.name
  $vmObj = [PSCustomObject] @{
    "Name" = $vm.name
    "Location" = ''
    "Workload" = "VMware"
    "Latest Backup" = $latestBackup
    "Latest Archive to One Location" = $latestOneArchive
    "Latest Archive to Two Locations" = $latestTwoArchive
    "SLA" = $vmSLA
  }
  $objList += $vmObj
}

Write-Host "Finished processing VMs" -foregroundcolor green

Write-Host "Getting a list of all SQL DBs"
$dbList = @()
$afterCursor = ''
do {
  $dbInventory = Get-SQLList -afterCursor $afterCursor
  $dbList += $dbInventory.edges.node
  $afterCursor = $dbInventory.pageInfo.endCursor
} while ($dbInventory.pageInfo.hasNextPage)

# Filter list by protected DBs
$protectedDBs = $dbList | Where { $_.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

$dbCount = $dbList.count

Write-Host "Found $dbCount protected DBs" -foregroundcolor green

Write-Host "Processing DBs..."

$count = 1

# Go through each protected DB and find the last backup that was archived
# to a single location and to two archive locations.
foreach ($db in $protectedDBs) {
  Write-Host "Processing $count / $dbCount"
  $backups = Get-BackupDetail -objId $db.dagid
  if ($backups.count -gt 0) {
    $latestBackup = $backups[0].date
    $archiveOne = $backups | Where { $_.snapshotRetentionInfo.archivalInfos.count -ge 1 }
    if ($archiveOne.count -gt 0) {
      $latestOneArchive = $archiveOne[0].date
    } else {
      $latestOneArchive = ''
    }
    $archiveTwo = $backups | Where { $_.snapshotRetentionInfo.archivalInfos.count -ge 2 }
    if ($archiveTwo.count -gt 0) {
      $latestTwoArchive = $archiveTwo[0].date
    } else {
      $latestTwoArchive = ''
    }
  } else {
    $latestBackup = ''
    $latestOneArchive = ''
    $latestTwoArchive = ''
  }
  $location = $db.physicalPath[-1].name
  $dbSLA = $db.effectivesladomain.name
  $dbObj = [PSCustomObject] @{
    "Name" = $db.name
    "Location" = $location
    "Workload" = "SQL"
    "Latest Backup" = $latestBackup
    "Latest Archive to One Location" = $latestOneArchive
    "Latest Archive to Two Locations" = $latestTwoArchive
    "SLA" = $dbSLA
  }
  $objList += $dbObj
  $count++
}

# Calculate the first day of the current month
$firstDayOfCurrentMonth = Get-Date -Day 1

# Subtract one day to get the last day of the previous month
$lastMonth = $firstDayOfCurrentMonth.AddDays(-2)

$objNoSecondArchiveSinceLastMonth = $objList | Where { $_.'Latest Archive to Two Location' -lt $lastMonth }

$objList | Export-CSV -Path $csvOutput -NoTypeInformation
Write-Host "Exporting all objects and last backup and archival dates to: $csvOutput" -foregroundcolor green

$objNoSecondArchiveSinceLastMonth | Export-CSV -Path $csvOutput2 -NoTypeInformation
Write-Host "Exporting all objects without an archival upload of a snapshot since the prior month to: $csvOutput2" -foregroundcolor green

# # Send an email with CSV attachment
# if ($sendEmail) {
#   Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
# }
