# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get the backup and archival details for VMware, SQL, Oracle,
Windows VG, NAS Share, and Active Directory Domain Controllers.

.DESCRIPTION
This script will get the backup and archival details for VMware, SQL, Oracle,
Windows VG, NAS Share, and Active Directory Domain Controllers.

The details of all backups are stored with the objects under: $objlist[].backups.
You can add a loop to export out all backup details if needed from there.

For the existing script, the results will be output to two CSVs.
1) Contains all the objects along with the most recent local and archived backups,
   and the oldest local and archived backups along with their expiration dates.
   The oldest backup information can help you find backups that might be retained
   longer than you expected them to be.
2) A list of objects that do not have a recent upload to the ARCH archival
   location as of the last month. This will highlight any compliance issues with
   the monthly uploads.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/1/25
Updated: 5/16/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-ArchivalDetails.ps1
Runs the script.

.EXAMPLE
./Get-ArchivalDetails.ps1 -Cluster <cluster_name>
Runs the script and filters against a specific cluster.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]
  # Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = ''
)
### VARIABLES - START ###

# List of SLA domains to filter out / ignore
$slaIgnoreList = @('IDOC-VM-BKP-STD')

# File location of the RSC service account json
# $serviceAccountPath = "./rsc-service-account-rr.json"
$serviceAccountPath = "./ArchivalDetailsScripts.json"

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

### VARIABLES - END ###

if ($psversiontable.psversion -lt 7) {
  Write-Error "PowerShell version is: $($psversiontable.psversion)"
  Write-Error "Please use PowerShell version 7+"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Ssl3
  [Net.ServicePointManager]::SecurityProtocol = "Tls, Tls11, Tls12, Ssl3"
}

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

# Holds list of objects to check archival for
$objList = @()

# Holds list of objects and archival result
$resultList = @()

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
Write-Host "Now filtering out objects by Protected, SLA, and Cluster" -foregroundcolor green
Write-Host ""

# Filter list by protected objects
$objList = $objList | Where-Object { $_.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

# Handle NAS separately since we need to look at the primary fileset to see what's protected
$nasListProtected = $nasList | Where-Object { $null -ne $_.primaryFileset -and $_.primaryFileset.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.primaryFileset.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

# Handle Windows VG separately since we need to look at the volumes to see what's protected
$vgListProtected = $vgList | Where-Object { $_.descendantConnection.edges.node.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
  $_.descendantConnection.edges.node.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

$protectedCount = $objList.count + $nasListProtected.count + $vgListProtected.count

Write-Host "Object count after filtering by Protected: $protectedCount" -foregroundcolor green

# Filter list by removing any in the SLA ignore list
$objList = $objList | Where-Object { $_.effectiveSlaDomain.name -notin $slaIgnoreList }

# Handle NAS and Windows VG separately since it's in a separate list
$nasListProtected = $nasListProtected | Where-Object { $_.primaryFileset.effectiveSlaDomain.name -notin $slaIgnoreList }
$vgListProtected = $vgListProtected | Where-Object { $_.descendantConnection.edges.node.effectiveSlaDomain.name -notin $slaIgnoreList }

# Combine the main object list with Windows VG List for final protected objects minus SLAs
$objList += $nasListProtected
$objList += $vgListProtected

Write-Host "SLAs to ignore: $slaIgnoreList" -foregroundcolor green
Write-Host "Object count after filtering out ignored SLAs: $($objList.count)" -foregroundcolor green

# Filter list by cluster if provided
if ($cluster -ne '' -and $cluster -ne $null) {
  Write-Host "Cluster name provided: $cluster" -foregroundcolor green
  $objList = $objList | Where-Object { $_.cluster.name -eq $cluster }
  Write-Host "Object count after filtering by cluster: $($objList.count)" -foregroundcolor green
} else {
  Write-Host "No cluster name provided so not filtering out by cluster name." -foregroundcolor green
}

$totalCount = $objList.count
Write-Host "Total number of objects to process: $totalCount" -foregroundcolor green
Write-Host "Processing $totalCount Objects..."
Write-Host ""

$count = 1

# Go through each object and find the last backup that was archived
# to a single location and to two archive locations.
foreach ($obj in $objList) {
  Write-Host "Processing $count / $totalCount"
  $workload = $obj.objectType
  if ($workload -eq 'Mssql') {
    $objID = $obj.dagid
  } elseif ($workload -eq 'OracleDatabase' -and $($obj.dataGuardType) -eq 'DATA_GUARD_MEMBER') {
    $objID = $obj.dataGuardGroup.id
  } elseif ($workload -eq 'NasShare') {
    $objID = $obj.primaryFileset.id
  } elseif ($workload -eq 'PhysicalHost') {
    $volGroup = $obj.hostVolumes | Where-Object { $_.volumeGroupId -ne $null }
    $volGroupString = $volGroup.mountPoints -join ','
    $objID = $volGroup[0].volumeGroupId
  } else {
    $objID = $obj.id
  }
  $backups = Get-BackupDetail -objId $objID
  $obj | Add-Member -MemberType NoteProperty -Name backupList -Value $backups
  # Reset all variables
  $latestBackupDate = ''
  $oldestLocalBackupDate = ''
  $oldestLocalBackupExpire = ''
  $latestARCHDate = ''
  $oldestARCHDate = ''
  $oldestARCHLocation = ''
  $oldestARCHExpire = ''
  $latestBKPDate = ''
  $oldestBKPDate = ''
  $oldestBKPLocation = ''
  $oldestBKPExpire = ''
  if ($backups.count -gt 0) {
    $latestBackupDate = $backups[0].date
    # Get all local backups
    $localBackups = $backups | Where-Object { $_.snapshotRetentionInfo.localInfo.count -ge 1 }
    if ($localBackups.count -gt 0) {
      # Get the oldest local backup
      $oldestLocalBackupDate = $($localBackups[-1].date)
      $oldestLocalBackupExpire = $($localBackups[-1].snapshotRetentionInfo.localInfo.expirationTime)
    }
    $rcvARCHList = $backups | Where-Object { ($_.snapshotRetentionInfo.archivalInfos.count -ge 2) -or
      ($_.snapshotRetentionInfo.archivalInfos[0].name -match 'ARCH') }
    if ($rcvARCHList.count -gt 0) {
      $latestARCHDate = $($rcvARCHList[0].date)
      $oldestARCHDate = $($rcvARCHList[-1].date)
      $oldestARCH = $rcvARCHList[-1].snapshotRetentionInfo.archivalInfos | Where-Object { $_.name -match 'ARCH' }
      $oldestARCHLocation = $oldestARCH.name
      $oldestARCHExpire = $oldestARCH.expirationTime
    }
  $rcvBKPList = $backups | Where-Object { $_.snapshotRetentionInfo.archivalInfos.count -ge 2 -or
    ($_.snapshotRetentionInfo.archivalInfos[0].name -match 'BKP') }
    if ($rcvBKPList.count -gt 0) {
      $latestBKPDate = $($rcvBKPList[0].date)
      $oldestBKPDate = $($rcvBKPList[-1].date)
      $oldestBKP = $rcvBKPList[-1].snapshotRetentionInfo.archivalInfos | Where-Object { $_.name -match 'BKP' }
      $oldestBKPLocation = $oldestBKP.name
      $oldestBKPExpire = $oldestBKP.expirationTime
    }
  }
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
  $objCluster = $obj.cluster.name
  $objInfo = [PSCustomObject] @{
    "Name" = $obj.name
    "Location" = $location
    "Workload" = $workload
    "Latest Backup" = $latestBackupDate
    "Latest Archive to ARCH" = $latestARCHDate
    "Latest Archive to BKP" = $latestBKPDate
    "Cluster" = $objCluster
    "SLA" = $objSLA
    "Oldest Local Backup" = $oldestLocalBackupDate
    "Oldest Local Backup Expire" = $oldestLocalBackupExpire
    "Oldest ARCH Date" = $oldestARCHDate
    "Oldest ARCH Location" = $oldestARCHLocation
    "Oldest ARCH Expiration" = $oldestARCHExpire
    "Oldest BKP Date" = $oldestBKPDate
    "Oldest BKP Location" = $oldestBKPLocation
    "Oldest BKP Expiration" = $oldestBKPExpire
  }
  $resultList += $objInfo
  $count++
}

### $objList() contains each object
### $objList.backups() contains the backup information for each object
### Can write some logic to loop through $objList().backups() to filter out by a particular date

# Comparison date to flag any objects that don't have archival to ARCH more recent to this date
$compDate = $date.AddDays(-32)
$objNoSecondArchiveSinceLastMonth = $resultList | Where-Object { $_.'Latest Archive to ARCH' -lt $compDate }

$resultList | Export-CSV -Path $csvOutput -NoTypeInformation
Write-Host "Exporting all objects and last backup and archival dates to: $csvOutput" -foregroundcolor green

$objNoSecondArchiveSinceLastMonth | Export-CSV -Path $csvOutput2 -NoTypeInformation
Write-Host "Exporting all objects without an archival upload of a snapshot since the prior month to: $csvOutput2" -foregroundcolor green

Write-Host ""
Write-Host "If expiration date is blank then that means it is the most recent backup/archival" -foregroundcolor green
Write-Host "and the expiration date is still Computing." -foregroundcolor green

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
