# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get the backup retention details for VMware, SQL, Oracle,
Windows VG, NAS Share, and Active Directory Domain Controllers.

.DESCRIPTION
This script will get the backup retention details for VMware, SQL, Oracle,
Windows VG, NAS Share, and Active Directory Domain Controllers.

Provide the following inputs:
1. $afterTimeEST: filter the backup list by this datetime
      Use this format: "2025-05-03 14:00:00" for May 3rd, 2025, 2pm EST
2. $numResults: the number of backups per object to return in the list
      Eg. Use '1' if you just want a specific backup on a specific date above

The results will be output to a CSV file for review.

Within the CSV, you will see the backup date for each object, along with
which locations the backup is stored in and the expiration date (UTC) for
each location. If there is no expiration date, then that means it is the last
backup so the expiration date is still being calculated.

There is a column in the CSV "Assign SLA ID". That can be used with a 2nd script
to assign a specific SLA to that specific snapshot ID.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 6/29/25

The script requires communication to RSC via outbound HTTPS (TCP 443).

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

Update this variable to point to your RSC Service Account JSON:
- $serviceAccountPath

.EXAMPLE
./Get-RubrikBackups.ps1 -afterTimeEST '2025-06-18 12:00:00' -numResults 1
Runs the script and gets the one backup for all objects taken after 6/18/25 2pm EST

#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # Filter for any backups after this date time in EST
  # Use this format: "2025-05-03 14:00:00"
  [Parameter(Mandatory=$false)]
  [string]$afterTimeEST = '',
  # Provide the first $numResults backup results, leave blank for all
  [Parameter(Mandatory=$false)]
  [int]$numResults = 1
)

# $afterTimeEST = "2025-06-18 12:00:00"
# $numResults = 1

# File location of the RSC service account json
$serviceAccountPath = "./rsc-gaia.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output of backups matching criteria
$csvOutput = "./rubrik_backup_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### VARIABLES - END ###

if ($psversiontable.psversion -lt 7) {
  Write-Error "PowerShell version is: $($psversiontable.psversion)"
  Write-Error "Please use PowerShell version 7+"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Ssl3
  [Net.ServicePointManager]::SecurityProtocol = "Tls, Tls11, Tls12, Ssl3"
}

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
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
if ($null -eq $serviceAccountFile.client_id) {
  $missingServiceAccount += "'client_id'"
}

if ($null -eq $serviceAccountFile.client_secret) {
  $missingServiceAccount += "'client_secret'"
}

if ($null -eq $serviceAccountFile.access_token_uri) {
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

# Get Oracle DB list
Function Get-OracleList {
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
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query OracleDatabasesListQuery(`$first: Int!, `$after: String, `$filter: [Filter!], `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
  oracleDatabases(
    after: `$after
    first: `$first
    filter: `$filter
    sortBy: `$sortBy
    sortOrder: `$sortOrder
  ) {
    edges {
      cursor
      node {
        id
        dbUniqueName
        name
        objectType
        dataGuardGroup {
          id
          dbUniqueName
          __typename
        }
        dataGuardType
        isRelic
        dbRole
        logBackupFrequency
        logRetentionHours
        hostLogRetentionHours
        numInstances
        numChannels
        sectionSizeInGigabytes
        useSecureThrift
        effectiveSlaDomain {
          objectSpecificConfigs {
            oracleConfig {
              frequency {
                duration
                unit
                __typename
              }
              __typename
            }
            __typename
          }
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
        ... on HierarchyObject {
          name
          __typename
        }
        ... on HierarchyObject {
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
          slaAssignment
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
        numTablespaces
        __typename
        osType
        osNames
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
  return $result.data.oracleDatabases
}  ### Function Get-OracleList

Function Get-VGList {
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
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query WindowsVolumeGroupHostListQuery(`$first: Int!, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]) {
  physicalHosts(
    hostRoot: WINDOWS_HOST_ROOT
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
        name
        objectType
        isArchived
        physicalChildConnection {
          edges {
            node {
              name
              id
              effectiveSlaDomain {
                id
              }
            }
          }
        }
        descendantConnection(typeFilter: [VolumeGroup]) {
          edges {
            node {
              id
              name
              objectType
              effectiveSlaDomain {
                id
                name
              }
              __typename
            }
            __typename
          }
          __typename
        }
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
        cluster {
          clusterNodeConnection {
            nodes {
              id
              status
              ipAddress
              __typename
            }
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
        primaryClusterLocation {
          id
          __typename
        }
        osType
        osName
        vfdState
        connectionStatus {
          connectivity
          timestampMillis
          __typename
        }
        hostVolumes {
          mountPoints
          fileSystemType
          size
          volumeId
          volumeGroupId
          __typename
        }
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
      startCursor
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
  return $result.data.physicalHosts
}  ### Function Get-VGList

Function Get-nasList {
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
        "field" = "NAS_SHARE_HIDDEN"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_DELETED_IN_CDM"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "NAS_SHARE_STALE"
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
  $query = "query NasAllSharesQuery(`$first: Int, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]) {
  nasShares(
    first: `$first
    after: `$after
    sortBy: `$sortBy
    sortOrder: `$sortOrder
    filter: `$filter
  ) {
    count
    edges {
      cursor
      node {
        id
        name
        effectiveSlaDomain {
          id
          name
        }
        isStale
        isNasShareManuallyAdded
        objectType
        logicalPath {
          fid
          objectType
          name
          __typename
        }
        nasSystem {
          id
          name
          vendorType
          effectiveSlaDomain {
            id
            name
          }
          __typename
        }
        primaryFileset {
          __typename
          id
          name
          effectiveSlaDomain {
            id
            name
          }
          snapshotDistribution {
            id
            totalCount
            __typename
          }
          templateFid
        }
        shareType
        isChangelistEnabled
        connectedThrough
        hostIdForRestore
        exportPoint
        descendantConnection {
          nodes {
            id
            replicatedObjects {
              cluster {
                id
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
        }
        cluster {
          status
          id
          version
          name
          __typename
        }
        isHidden
        isRelic
        cdmId
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
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.nasshares
}  ### Function Get-nasList

Function Get-DCs {
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
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query OnPremAdDomainControllerListQuery(`$first: Int, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]) {
  unifiedActiveDirectoryDomainControllers(
    first: `$first
    after: `$after
    sortBy: `$sortBy
    sortOrder: `$sortOrder
    filter: `$filter
  ) {
    count
    edges {
      cursor
      node {
        id
        name
        objectType
        dcLocation
        fsmoRoles
        activeDirectoryDomain {
          name
          cluster {
            id
            name
            version
            __typename
          }
          __typename
        }
        serverRoles
        slaPauseStatus
        isRelic
        snapshotConnection {
          count
          __typename
        }
        agentUuid
        rbsStatus {
          connectivity
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
          slaAssignment
          __typename
        }
        ... on CdmHierarchyObject {
          replicatedObjectCount
          cluster {
            id
            name
            version
            status
            pauseStatus
            __typename
            clusterNodeConnection {
              count
              nodes {
                ipAddress
                clusterId
                status
                __typename
              }
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
      hasNextPage
      endCursor
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
  return $result.data.unifiedActiveDirectoryDomainControllers
}  ### Function Get-DCs

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
        isOnDemandSnapshot
        ... on CdmSnapshot {
          cdmVersion
          isRetentionLocked
          isDownloadedSnapshot
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
        }
      }
    }
    pageInfo {
      endCursor
      hasNextPage
      __typename
    }
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

# Convert user supplied EST to UTC for comparisons
$estTime = [DateTime]::SpecifyKind([DateTime]::ParseExact($afterTimeEST, 'yyyy-MM-dd HH:mm:ss', $null), [DateTimeKind]::Unspecified)
$afterTimeUTC = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($estTime, 'Eastern Standard Time', 'UTC')

# Holds list of objects with their backup details
$objList = @()

Write-Host "Getting a list of all VMs"
$vmList = @()
$afterCursor = ''
do {
  $vmInventory = Get-VMList -afterCursor $afterCursor
  $vmList += $vmInventory.edges.node
  $afterCursor = $vmInventory.pageInfo.endCursor
} while ($vmInventory.pageInfo.hasNextPage)

Write-Host "Found $($vmList.count) VMs" -foregroundcolor green

$objList += $vmList

Write-Host "Getting a list of all SQL DBs"
$sqlList = @()
$afterCursor = ''
do {
  $sqlInventory = Get-SQLList -afterCursor $afterCursor
  $sqlList += $sqlInventory.edges.node
  $afterCursor = $sqlInventory.pageInfo.endCursor
} while ($sqlInventory.pageInfo.hasNextPage)

Write-Host "Found $($sqlList.count) DBs" -foregroundcolor green

$objList += $sqlList

Write-Host "Getting a list of all Oracle DBs"
$oracleList = @()
$afterCursor = ''
do {
  $oracleInventory = Get-OracleList -afterCursor $afterCursor
  $oracleList += $oracleInventory.edges.node
  $afterCursor = $oracleInventory.pageInfo.endCursor
} while ($oracleInventory.pageInfo.hasNextPage)

Write-Host "Found $($oracleList.count) DBs" -foregroundcolor green

$objList += $oracleList

Write-Host "Getting a list of all Active Directory Domain Controllers"
$afterCursor = ''
$adList = Get-DCs -afterCursor $afterCursor
$adList = $adList.edges.node

Write-Host "Found $($adList.count) AD Domain Controllers" -foregroundcolor green

$objList += $adList

# NAS shares will not be added to $objList yet since it needs to be separately filtered
Write-Host "Getting a list of all NAS shares"
$nasList = @()
$afterCursor = ''
do {
  $nasInventory = Get-nasList -afterCursor $afterCursor
  $nasList += $nasInventory.edges.node
  $afterCursor = $nasInventory.pageInfo.endCursor
} while ($nasInventory.pageInfo.hasNextPage)

Write-Host "Found $($nasList.count) NAS shares" -foregroundcolor green

# Windows VG will not be added to $objList yet since it needs to be separately filtered
Write-Host "Getting a list of all Windows Volume Groups"
$vgList = @()
$afterCursor = ''
do {
  $vgInventory = Get-VGList -afterCursor $afterCursor
  $vgList += $vgInventory.edges.node
  $afterCursor = $vgInventory.pageInfo.endCursor
} while ($vgInventory.pageInfo.hasNextPage)

Write-Host "Found $($vgList.count) Volume Groups" -foregroundcolor green

$allObjCount = $objList.count + $nasList.count + $vgList.count

Write-Host ""
Write-Host "Total object count so far: $allObjCount" -foregroundcolor green
Write-Host "Now filtering out objects by objects that are being Protected" -foregroundcolor green
Write-Host ""

# Filter list by protected objects
$objListProtected = $objList | Where-Object { $_.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

# Handle NAS separately since we need to look at the primary fileset to see what's protected
$nasListProtected = $nasList | Where-Object { $null -ne $_.primaryFileset -and $_.primaryFileset.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.primaryFileset.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

# Handle Windows VG separately since we need to look at the volumes to see what's protected
$vgListProtected = $vgList | Where-Object { $_.descendantConnection.edges.node.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.descendantConnection.edges.node.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

$allObjProtected = $objListProtected + $nasListProtected + $vgListProtected
$protectedCount = $allObjProtected.count

Write-Host "Object count after filtering by Protected: $protectedCount" -foregroundcolor green
Write-Host "Processing $protectedCount Objects..."
Write-Host ""

# Holds list of backups matching time frame
$resultList = @()

$count = 1

# Go through each object and get the backup detail list for each
foreach ($obj in $allObjProtected) {
  Write-Host "[$count / $protectedCount] Getting details for: $($obj.name) ($($obj.objectType))"
  # Get the object ID for each object, different types may have it at different levels
  $objID = ''
  $workload = $obj.objectType
  if ($workload -eq 'Mssql') {
    $objID = $obj.dagid
  } elseif ($workload -eq 'OracleDatabase' -and $($obj.dataGuardType) -eq 'DATA_GUARD_MEMBER') {
    $objID = $obj.dataGuardGroup.id
  } elseif ($workload -eq 'NasShare') {
    $objID = $obj.primaryFileset.id
  } elseif ($workload -eq 'PhysicalHost') {
    $volGroup = $null
    $volGroup = $obj.hostVolumes | Where-Object { $_.volumeGroupId -ne $null }
    if ($volGroup -eq $null) {
      Write-Error "Error processing: $($obj.name), $($obj.objecttype)"
    } else {
      $volGroupString = $volGroup.mountPoints -join ','
      $objID = $volGroup[0].volumeGroupId
    }
  } else {
    $objID = $obj.id
  }
  # Get the backup retention details for the object
  $backups = Get-BackupDetail -objId $objID
  # Add the backup retention details to the existing object
  $obj | Add-Member -MemberType NoteProperty -Name backupList -Value $backups
  # Filter the backups matching after the provided EST -> UTC date
  $backupsAfterDate = $obj.backupList | Where { $_.date -gt $afterTimeUTC }
  # If $numReuslts was provided, only select the number of backups needed
  if ($numResults -ne '' -and $numResults -ne $null) {
    $backupsAfterDate = $backupsAfterDate | Select-Object -Last $numResults
  }
  foreach ($backup in $backupsAfterDate) {
    if ($workload -eq 'PhysicalHost') {
      $location = $volGroupString
      $objSLA = $obj.descendantConnection.edges.node.effectiveSlaDomain.name
    } elseif ($workload -eq 'NasShare') {
      $location = $obj.nassystem.name
      $objSLA = $obj.primaryFileset.effectiveSlaDomain.name
    } elseif ($workload -eq 'ACTIVE_DIRECTORY_DOMAIN_CONTROLLER') {
      $location = $obj.dcLocation
      $objSLA = $obj.effectivesladomain.name
    } else {
      $location = $obj.physicalPath[-1].name
      $objSLA = $obj.effectivesladomain.name
    }
    $localInfo = ''
    $archivalInfos = ''
    $replicationInfos = ''
    # Gather the local backup info it there is a local backup
    if ($backup.snapshotRetentionInfo.localInfo.name -ne $null) {
      $localInfo = $backup.snapshotRetentionInfo.localInfo.name + ", " +
        $backup.snapshotRetentionInfo.localInfo.expirationTime
    } else {
      $localInfo = ''
    }
    if ($backup.snapshotRetentionInfo.archivalInfos.count -gt 0) {
      foreach ($arc in $backup.snapshotRetentionInfo.archivalInfos) {
        if ($archivalInfos -eq '') {
          $archivalInfos = $arc.name + ", " + $arc.ExpirationTime
        } else {
          $archivalInfos = $archivalInfos + ", " + $arc.name + ", " + $arc.ExpirationTime
        }
      }
    } else {
      $archivalInfos = ''
    }
    if ($backup.snapshotRetentionInfo.replicationInfos.count -gt 0) {
      foreach ($repl in $backup.snapshotRetentionInfo.replicationInfos) {
        if ($replicationInfos -eq '') {
          $replicationInfos = $repl.name + ", " + $repl.ExpirationTime
        } else {
          $replicationInfos = $replicationInfos + ", " + $repl.name + ", " + $repl.ExpirationTime
        }
      }
    } else {
      $replicationInfos = ''
    }
    # Convert the UTC DateTime to Eastern Time
    $estTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $estDateTime = [TimeZoneInfo]::ConvertTimeFromUtc($($backup.date), $estTimeZone)
    $backupDateEST = $estDateTime.ToString('MM/dd/yyyy HH:mm:ss')
    $backupInfo = [PSCustomObject] @{
      "Cluster" = $obj.cluster.name
      "Name" = $obj.name
      "Location" = $location
      "Workload" = $workload
      "SLA" = $objSLA
      "Backup Date EST" = $backupDateEST
      "Local Info Exp UTC" = $localInfo
      "Archival Info Exp UTC" = $archivalInfos
      "Replication Info Exp UTC" = $replicationInfos
      "Custom Retention" = $backup.snapshotRetentionInfo.isCustomRetentionApplied
      "Legal Hold Info" = $backup.legalHoldInfo
      "Snapshot ID" = $backup.id
      "Assign SLA ID" = ""
    }
    $resultList += $backupInfo
  }
  $count++
}

$resultList | Export-CSV -Path $csvOutput -NoTypeInformation
Write-Host "Exporting the details to: $csvOutput" -foregroundcolor green
Write-Host "For backup date (EST): $afterTimeEST, number of backups for each object: $numResults" -foregroundcolor green
Write-Host ""
Write-Host "If expiration date is blank then that means it is the most recent backup/archival" -foregroundcolor green
Write-Host "and the expiration date is still Computing." -foregroundcolor green
