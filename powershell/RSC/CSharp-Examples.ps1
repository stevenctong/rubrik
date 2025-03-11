<#
.SYNOPSIS
Example to use RSC Service Account for REST API authentication and conversion
of other C Sharp functions.

.DESCRIPTION
Example to use RSC Service Account for REST API authentication and conversion
of other C Sharp functions.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/9/25

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE

#>

param (
  [CmdletBinding()]
  # RSC Service Account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = ''
)

$date = Get-Date



###### RUBRIK SECURITY CLOUD AUTHENTICATION - BEGIN ######
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
###### RUBRIK SECURITY CLOUD - END ######



###### RUBRIK CDM REST API AUTHENTICATION - BEGIN ######

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

$RestSplat = @{
    Method = 'Post'
    ContentType = "application/json"
    URI = "https://$cluster/api/v1/service_account/session"
    Body = @{
        serviceAccountId = "$($serviceAccountFile.client_id)"
        secret = "$($serviceAccountFile.client_secret)"
    } | ConvertTo-Json
}

if ($PSVersiontable.PSVersion.Major -gt 5) {$RestSplat.SkipCertificateCheck = $true}
$response = Invoke-RestMethod @RestSplat -Verbose
$token = $response.token
$contentType = "application/json"
$headers = @{'Authorization' = "Bearer $($Token)"}
$global:rubrikConnection = @{
    id      = $response.sessionId
    userId  = $null
    token   = $Token
    server  = $Server
    header  = $head
    time    = (Get-Date)
    authType = 'ServiceAccount'
}
if ($token -ne '') {
  Write-Host "Connected to Rubrik cluster: $cluster"
}

###### RUBRIK CDM REST API AUTHENTICATION - END ######


Function Test {
  $variables = [PSCustomObject]@{
    "includeRscNativeObjectPendingSla" = false
    "first" = 50
    "filter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "false"
        ]
      },
      {
        "field": "IS_REPLICATED",
        "texts": [
          "false"
        ]
      },
      {
        "field": "NAS_SHARE_HIDDEN",
        "texts": [
          "false"
        ]
      },
      {
        "field": "IS_DELETED_IN_CDM",
        "texts": [
          "false"
        ]
      },
      {
        "field": "NAS_SHARE_STALE",
        "texts": [
          "false"
        ]
      }
    ],
    "sortBy": "NAME",
    "sortOrder": "ASC"
  }
  $query = "query NasAllSharesQuery(`$first: Int, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!], `$includeRscNativeObjectPendingSla: Boolean = false) {
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
        isStale
        isNasShareManuallyAdded
        logicalPath {
          fid
          objectType
          name
          __typename
        }
        ... on HierarchyObject {
          allOrgs {
            fullName
            __typename
          }
          __typename
        }
        nasSystem {
          id
          name
          vendorType
          __typename
        }
        primaryFileset {
          __typename
          id
          snapshotDistribution {
            id
            totalCount
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
            ... on PolarisHierarchyObject {
              rscNativeObjectPendingSla `@include(if: `$includeRscNativeObjectPendingSla) {
                id
                name
                __typename
              }
              __typename
            }
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
}
  "
  $payload = @{
    "query" = $query
    "variables" = $variables
  } | ConvertTo-JSON -Depth 100
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $payload -Headers $headers)
  return $result.data.nasShares.edges.node
}






# Get NAS share list
Function Get-NASShares {
  $variables = @{
    "first" = 100
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
        "field" = "NAS_SHARE_HIDDEN"
        "texts" = @(
          "false"
        )
      }
      @{
        "field" = "IS_DELETED_IN_CDM"
        "texts" = @(
          "false"
        )
      }
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
        isStale
        isNasShareManuallyAdded
        cluster {
          id
        }
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
          __typename
        }
        primaryFileset {
          __typename
          id
          snapshotDistribution {
            id
            totalCount
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
            name
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
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.nasshares.edges.node
}  ### Function Get-NASShares


# Get snapshot list for a specific NAS Share
Function Get-NASSnapshots {
  param (
    [CmdletBinding()]
    # NAS Fileset Directory ID
    [Parameter(Mandatory=$true)]
    [string]$nasShareID
  )
  $currentTime = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
  $oneYearAgo = (Get-Date).AddYears(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
  $variables = @{
    "snappableFid" = $nasShareID
    "snapshotGroupBy" = "Day"
    "timeRange" = @{
      "start" = $oneYearAgo
      "end" = $currentTime
    }
    "timezoneOffset" = -7
  }
  $query = "query NASCalendarMonthViewQuery(`$snappableFid: UUID!, `$snapshotGroupBy: CdmSnapshotGroupByEnum!, `$timeRange: TimeRangeInput!, `$timezoneOffset: Float, `$timezone: Timezone) {
  snappable: nasShare(fid: `$snappableFid) {
    id
    name
    descendantConnection(typeFilter: [NAS_FILESET]) {
      nodes {
        ... on NasFileset {
          snapshotGroupBySummary(groupBy: `$snapshotGroupBy, filter: {timeRange: `$timeRange}, timezoneOffset: `$timezoneOffset, timezone: `$timezone) {
            nodes {
              cdmSnapshots {
                count
                nodes {
                  snappableId
                  id
                  date
                  isIndexed
                  isUnindexable
                  isQuarantined
                  __typename
                }
              }
            }
          }
        }
      }
    }
  }
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.snappable.descendantConnection.nodes
}  ### Function Get-NASSnapshots



# Assign a "Forever" SLA to a snapshot
Function Assign-ForeverSLA {
  param (
    [CmdletBinding()]
    # RSC Snapshot ID
    [Parameter(Mandatory=$true)]
    [string]$snapshotID
  )
  $variables = @{
    "userNote" = ""
    "globalSlaAssignType" = "doNotProtect"
    "snapshotFids" = @(
      $snapshotID
    )
    "globalSlaOptionalFid" = $null
  }
  $query = "mutation ChangeSnapshotsRetentionMutation(`$globalSlaAssignType: SlaAssignTypeEnum!, `$snapshotFids: [UUID!]!, `$globalSlaOptionalFid: UUID, `$userNote: String) {
  assignRetentionSLAToSnapshots(globalSlaAssignType: `$globalSlaAssignType, snapshotFids: `$snapshotFids, globalSlaOptionalFid: `$globalSlaOptionalFid, userNote: `$userNote) {
    success
    __typename
  }
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Assign-ForeverSLA

# Delete a snapshot
Function Delete-Snapshot {
  param (
    [CmdletBinding()]
    # RSC Snapshot ID
    [Parameter(Mandatory=$true)]
    [string]$snapshotID
  )
  $variables = @{
    "input" = @{
      "snapshotIds" = $snapshotID
    }
  }
  $query = "mutation DeleteUnmanagedSnapshotsMutation(`$input: DeleteUnmanagedSnapshotsInput!) {
  deleteUnmanagedSnapshots(input: `$input) {
    success
    __typename
  }
}
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Delete-Snapshot
