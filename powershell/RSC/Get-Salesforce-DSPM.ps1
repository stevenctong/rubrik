# https://www.rubrik.com/api
<#
.SYNOPSIS
This script gets sensitivity details from Salesforce.

.DESCRIPTION
This script gets sensitivity details from Salesforce.

This script requires communication to RSC via outbound HTTPS (TCP 443).

This script requires PowerShell v7+.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/7/26

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

For Service Account custom role:
** Create a role with 'View' permission for Reports

Create your custom report and grab the report ID. The report ID number in the URL of ther report.


.EXAMPLE
./Get-Salesforce-DSPM.ps1
Gets Salesforce sensitivity details.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]
  # Comment
  [Parameter(Mandatory=$false)]
  [string]$filler = 'filler'
)

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmm")
$utcDate = $date.ToUniversalTime()

$csvOutput = "./rubrik_dspm_salesforce-$dateString.csv"

# Filepath for the RSC Service Account json creds
$serviceAccountPath = './rsc-saasapps.json'

### End Variables section

if ($PSVersionTable.PSVersion.Major -le 5) {
  Write-Error "Current PS version: $PSVersionTable.PSVersion.Major"
  Write-Error "Script requires PS version 7+"
  Write-Error "This script may have errors running"
}

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host "Attempting to read the Service Account file: $serviceAccountPath"
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

$payload = @{
  grant_type = "client_credentials";
  client_id = $serviceAccountFile.client_id;
  client_secret = $serviceAccountFile.client_secret
}

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

Write-Host "Connecting to RSC to get an auth token: $rubrikURL"
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

if ($null -eq $rubrikConnection.accessToken) {
  throw "Error getting access token, exiting..."
}

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

Write-Host "Successfully connected to: $rubrikURL" -foregroundcolor green

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Get list of all Salesforce objects w/sensitive hits
Function Get-SensitiveSalesforceObjects {
  param (
    [CmdletBinding()]
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "includeDocumentTypes" = $false
    "day" = "2026-01-07"
    "timezone" = "America/Los_Angeles"
    "objectTypes" = @(
      "SALESFORCE_OBJECT"
    )
    "searchObjectName" = ""
    "sortBy" = "ACTIVE_VIOLATIONS"
    "sortOrder" = "DESC"
    "includeWhitelistedResults" = $false
    "selectedPlatforms" = @(
      "PLATFORM_SALESFORCE"
    )
    "clusterIdsFilter" = @()
    "dataTypeIdsFilter" = @()
    "documentTypesFilter" = @()
    "riskLevelsFilter" = @()
    "backupStatusFilter" = @()
    "slaIdsFilter" = @()
    "sids" = @()
    "policyIdsFilter" = @()
    "includeRscNativeObjectPendingSla" = $true
    "mipLabelsFilter" = @()
    "includeInsightsMarker" = $true
    "first" = 200
  }
  if ($afterCursor -ne '') {
    $variables["after"] = $afterCursor
  }
  $query = 'query ObjectInventoryListQuery($day: String!, $timezone: String!, $objectTypes: [DataGovObjectType!]!, $searchObjectName: String, $sortBy: String, $sortOrder: SortOrder, $analysisStatusesFilter: [AnalysisStatus!], $policyIdsFilter: [String!], $riskLevelsFilter: [RiskLevelType!], $clusterIdsFilter: [String!], $subscriptionIdsFilter: [String!], $includeWhitelistedResults: Boolean, $first: Int!, $after: String, $includeInsightsMarker: Boolean, $insightsMetadataId: String, $sids: [String!], $platformCategoryFilter: [PlatformCategory!], $selectedPlatforms: [Platform!], $selectedCloudAccountIds: [String!], $selectedRegions: [String!], $dataTypeIdsFilter: [String!], $documentTypesFilter: [UUID!], $backupStatusFilter: [BackupStatus!], $slaIdsFilter: [String!], $encryptionFilter: [Encryption!], $loggingFilter: [Logging!], $networkAccessFilter: [NetworkAccess!], $lastAccessTimeRange: UserTimeRangeInput, $creationTimeRange: UserTimeRangeInput, $lastScanTimeRange: UserTimeRangeInput, $objectTagsFilter: ObjectTagsFilterInput, $includeRscNativeObjectPendingSla: Boolean!, $violationSeverityFilter: [ViolationSeverity!], $exposureFilter: [OpenAccessType!], $mipLabelsFilter: [MipLabelsFilterInput!], $scanResultCategoriesFilter: [ScanResultCategory!], $includeDocumentTypes: Boolean = false) {
  policyObjs(
    day: $day
    timezone: $timezone
    workloadTypes: $objectTypes
    searchObjectName: $searchObjectName
    sortBy: $sortBy
    sortOrder: $sortOrder
    analysisStatusesFilter: $analysisStatusesFilter
    policyIdsFilter: $policyIdsFilter
    riskLevelsFilter: $riskLevelsFilter
    clusterIdsFilter: $clusterIdsFilter
    subscriptionIdsFilter: $subscriptionIdsFilter
    includeWhitelistedResults: $includeWhitelistedResults
    first: $first
    after: $after
    includeInsightsMarker: $includeInsightsMarker
    sids: $sids
    insightsMetadataId: $insightsMetadataId
    platformCategoryFilter: $platformCategoryFilter
    platformFilter: $selectedPlatforms
    cloudAccountIdsFilter: $selectedCloudAccountIds
    regionsFilter: $selectedRegions
    dataTypeIdsFilter: $dataTypeIdsFilter
    documentTypesFilter: $documentTypesFilter
    backupStatusFilter: $backupStatusFilter
    slaIdsFilter: $slaIdsFilter
    encryptionFilter: $encryptionFilter
    loggingFilter: $loggingFilter
    networkAccessFilter: $networkAccessFilter
    lastAccessTimeRange: $lastAccessTimeRange
    creationTimeRange: $creationTimeRange
    lastScanTimeRange: $lastScanTimeRange
    objectTagsFilter: $objectTagsFilter
    violationSeverityFilter: $violationSeverityFilter
    exposureFilter: $exposureFilter
    mipLabelsFilter: $mipLabelsFilter
    scanResultCategoriesFilter: $scanResultCategoriesFilter
  ) {
    edges {
      cursor
      node {
        id
        snapshotFid
        snapshotTimestamp
        shareType
        analysisStatus
        riskLevel
        accessRiskReasons
        isUserAccessEnabledObject
        isUserActivityEnabled
        mipLabelsSummary {
          mipLabel {
            siteId
            labelName
            labelId
            hasProtection
            __typename
          }
          filesCount {
            violatedCount
            totalCount
            __typename
          }
          __typename
        }
        sensitiveFiles {
          highRiskFileCount {
            totalCount
            violatedCount
            __typename
          }
          mediumRiskFileCount {
            totalCount
            violatedCount
            __typename
          }
          lowRiskFileCount {
            totalCount
            violatedCount
            __typename
          }
          noRiskFileCount {
            totalCount
            violatedCount
            __typename
          }
          totalFileCount {
            totalCount
            violatedCount
            __typename
          }
          __typename
        }
        unusedSensitiveFiles {
          totalFileCount {
            totalCount
            violatedCount
            __typename
          }
          __typename
        }
        rootFileResult {
          hits {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          analyzerGroupResults {
            analyzerGroup {
              groupType
              id
              name
              __typename
            }
            analyzerResults {
              hits {
                totalHits
                violations
                __typename
              }
              analyzer {
                id
                name
                analyzerType
                __typename
              }
              __typename
            }
            hits {
              totalHits
              violations
              violationsDelta
              totalHitsDelta
              __typename
            }
            __typename
          }
          filesWithHits {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          openAccessFiles {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          openAccessFolders {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          openAccessFilesWithHits {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          staleFiles {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          staleFilesWithHits {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          openAccessStaleFiles {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          numActivities
          numActivitiesDelta
          __typename
        }
        userCounts {
          highRiskCount {
            totalCount
            violatedCount
            __typename
          }
          mediumRiskCount {
            totalCount
            violatedCount
            __typename
          }
          lowRiskCount {
            totalCount
            violatedCount
            __typename
          }
          totalCount {
            violatedCount
            __typename
          }
          __typename
        }
        snappable {
          id
          name
          objectType
          slaAssignment
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
          ... on CloudDirectHierarchyObject {
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
            rscNativeObjectPendingSla @include(if: $includeRscNativeObjectPendingSla) {
              id
              name
              __typename
            }
            __typename
          }
          __typename
          ... on VsphereVm {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on LinuxFileset {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on ShareFileset {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on WindowsFileset {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on NutanixVm {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on HyperVVirtualMachine {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on VolumeGroup {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
          ... on O365Onedrive {
            userPrincipalName
            __typename
          }
          ... on O365SharepointDrive {
            url
            __typename
          }
          ... on AzureNativeVirtualMachine {
            region
            azureResourceGroupDetails {
              azureSubscriptionDetails {
                id
                name
                __typename
              }
              __typename
            }
            __typename
          }
          ... on AzureNativeManagedDisk {
            region
            azureResourceGroupDetails {
              azureSubscriptionDetails {
                id
                name
                __typename
              }
              __typename
            }
            __typename
          }
          ... on CloudDirectNasExport {
            exportPath
            __typename
          }
          ... on CloudDirectNasShare {
            exportPath
            __typename
          }
          ... on CloudDirectHierarchyObject {
            cluster {
              id
              name
              __typename
            }
            __typename
          }
        }
        hasInsights
        __typename
        objectType
        assetMetadata {
          name
          platform
          platformCategory
          cloudAccountInfo {
            accountId
            accountName
            __typename
          }
          clusterInfo {
            clusterUuid
            clusterName
            __typename
          }
          size
          physicalHost
          region
          creationTime
          lastAccessTime
          backupStatus
          rubrikSlaInfo {
            slaId
            slaName
            __typename
          }
          encryption
          logging
          networkAccess
          __typename
        }
        riskHits {
          highRiskHits {
            totalHits
            violatedHits
            __typename
          }
          mediumRiskHits {
            totalHits
            violatedHits
            __typename
          }
          lowRiskHits {
            totalHits
            violatedHits
            __typename
          }
          noRiskHits {
            totalHits
            violatedHits
            __typename
          }
          __typename
        }
        scanStatus
        scanErrorInfo {
          flowErrorCode
          scanResultDetails {
            category
            description
            __typename
          }
          __typename
        }
        dataTypeResults {
          dataType {
            id
            name
            __typename
          }
          result {
            totalHits
            totalViolatedHits
            __typename
          }
          __typename
        }
        violationSeverity
        exposureSummary {
          exposureType
          fileCount {
            totalCount
            violatedCount
            __typename
          }
          __typename
        }
        documentTypesSummary @include(if: $includeDocumentTypes) {
          id
          name
          filesCount {
            totalCount
            violatedCount
            __typename
          }
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
}'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.policyObjs
} ### Get-SensitiveSalesforceObjects


# Get details of an object
Function Get-SensitiveDetails {
  param (
    [CmdletBinding()]
    # Object ID
    [Parameter(Mandatory=$false)]
    [string]$objectID = '',
    # Snapshot ID
    [Parameter(Mandatory=$false)]
    [string]$snapshotID = ''
  )
    $variables = @{
    "includeDocumentTypes" = $false
    "snappableFid" = $objectID
    "snapshotFid" = $snapshotID
    "filters" = @{
      "accessVia" = "ACCESS_TYPE_UNSPECIFIED"
      "fileType" = "HITS"
      "searchText" = ""
      "snappablePaths" = @(
        @{
          "snappableFid" = "8c0e209a-3d05-4a0f-a85b-38968b7ed78e"
          "stdPath" = ""
        }
      )
      "whitelistEnabled" = $true
      "riskLevelTypesFilter" = @()
      "documentTypesFilter" = @()
      "exposureFilter" = @()
      "mipLabelsFilter" = @()
    }
    "sort" = @{
      "dataTypeId" = ""
      "sortBy" = "HITS"
      "sortOrder" = "DESC"
    }
    "timezone" = "America/Los_Angeles"
    "first" = 25
  }
  $query = 'query ObjectInventoryFilesQuery($first: Int!, $after: String, $snappableFid: String!, $snapshotFid: String!, $filters: ListFileResultFiltersInput, $sort: FileResultSortInput, $timezone: String!, $includeDocumentTypes: Boolean = false) {
  policyObj(snappableFid: $snappableFid, snapshotFid: $snapshotFid) {
    id: snapshotFid
    fileResultConnection(
      first: $first
      after: $after
      filter: $filters
      sort: $sort
      timezone: $timezone
    ) {
      edges {
        cursor
        node {
          nativePath
          stdPath
          filename
          mode
          size
          lastAccessTime
          lastModifiedTime
          creationTime
          lastScanTime
          directory
          createdBy
          modifiedBy
          numDescendantFiles
          numDescendantErrorFiles
          numDescendantSkippedExtFiles
          numDescendantSkippedSizeFiles
          errorCode
          hits {
            totalHits
            violations
            violationsDelta
            totalHitsDelta
            __typename
          }
          filesWithHits {
            totalHits
            violations
            __typename
          }
          openAccessFilesWithHits {
            totalHits
            violations
            __typename
          }
          staleFilesWithHits {
            totalHits
            violations
            __typename
          }
          analyzerGroupResults {
            analyzerGroup {
              groupType
              id
              name
              __typename
            }
            analyzerResults {
              hits {
                totalHits
                violations
                __typename
              }
              analyzer {
                id
                name
                analyzerType
                __typename
              }
              __typename
            }
            hits {
              totalHits
              violations
              violationsDelta
              totalHitsDelta
              __typename
            }
            __typename
          }
          sensitiveFiles {
            highRiskFileCount {
              totalCount
              violatedCount
              __typename
            }
            mediumRiskFileCount {
              totalCount
              violatedCount
              __typename
            }
            lowRiskFileCount {
              totalCount
              violatedCount
              __typename
            }
            noRiskFileCount {
              totalCount
              violatedCount
              __typename
            }
            totalFileCount {
              totalCount
              violatedCount
              __typename
            }
            __typename
          }
          sensitiveHits {
            highRiskHits {
              totalHits
              violatedHits
              __typename
            }
            mediumRiskHits {
              totalHits
              violatedHits
              __typename
            }
            lowRiskHits {
              totalHits
              violatedHits
              __typename
            }
            noRiskHits {
              totalHits
              violatedHits
              __typename
            }
            __typename
          }
          analyzerRiskHits {
            highRiskHits {
              totalHits
              violatedHits
              __typename
            }
            mediumRiskHits {
              totalHits
              violatedHits
              __typename
            }
            lowRiskHits {
              totalHits
              violatedHits
              __typename
            }
            noRiskHits {
              totalHits
              violatedHits
              __typename
            }
            __typename
          }
          analyzerResults {
            hits {
              totalHits
              violations
              __typename
            }
            analyzer {
              id
              name
              analyzerType
              __typename
            }
            __typename
          }
          openAccessType
          stalenessType
          numActivities
          numActivitiesDelta
          exposureSummary {
            exposureType
            fileCount {
              totalCount
              violatedCount
              __typename
            }
            __typename
          }
          dbEntityType
          mipLabelsSummary {
            mipLabel {
              siteId
              labelName
              labelId
              hasProtection
              __typename
            }
            filesCount {
              violatedCount
              totalCount
              __typename
            }
            __typename
          }
          documentTypesSummary @include(if: $includeDocumentTypes) {
            id
            name
            filesCount {
              totalCount
              violatedCount
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
      hasLatestData
      __typename
    }
    __typename
  }
}'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.policyObj.fileResultConnection.edges.node
} ### Get-SensitiveDetails


# Get sensitive details on a file within an object
Function Get-FileDetails {
  param (
    [CmdletBinding()]
    # Object ID
    [Parameter(Mandatory=$true)]
    [string]$objectID = '',
    # Snapshot ID
    [Parameter(Mandatory=$true)]
    [string]$snapshotID = '',
    # Path
    [Parameter(Mandatory=$true)]
    [string]$path = ''
  )
  $variables = @{
    "snappableFid" = $objectID
    "snapshotFid" = $snapshotID
    "stdPath" = $path
  }
  $query = 'query FileSchemaResultsQuery($snapshotFid: String!, $snappableFid: String!, $stdPath: String!, $sort: FileStructureSortInput) {
  fileSchemaResults(
    snapshotFid: $snapshotFid
    snappableFid: $snappableFid
    stdPath: $stdPath
    sort: $sort
  ) {
    nodes {
      ... on AnalyzedColumn {
        columnName
        columnType
        columnDatatypeResults {
          dataType {
            id
            name
            analyzerType
            __typename
          }
          result {
            id
            totalHits
            totalViolatedHits
            __typename
          }
          __typename
        }
        __typename
      }
      columnResults {
        ... on AnalyzedColumn {
          columnName
          columnType
          columnDatatypeResults {
            dataType {
              id
              name
              analyzerType
              __typename
            }
            result {
              id
              totalHits
              totalViolatedHits
              __typename
            }
            __typename
          }
          __typename
        }
        columnResults {
          ... on AnalyzedColumn {
            columnName
            columnType
            columnDatatypeResults {
              dataType {
                id
                name
                analyzerType
                __typename
              }
              result {
                id
                totalHits
                totalViolatedHits
                __typename
              }
              __typename
            }
            __typename
          }
          columnResults {
            ... on AnalyzedColumn {
              columnName
              columnType
              columnDatatypeResults {
                dataType {
                  id
                  name
                  analyzerType
                  __typename
                }
                result {
                  id
                  totalHits
                  totalViolatedHits
                  __typename
                }
                __typename
              }
              __typename
            }
            columnResults {
              ... on AnalyzedColumn {
                columnName
                columnType
                columnDatatypeResults {
                  dataType {
                    id
                    name
                    analyzerType
                    __typename
                  }
                  result {
                    id
                    totalHits
                    totalViolatedHits
                    __typename
                  }
                  __typename
                }
                __typename
              }
              columnResults {
                ... on AnalyzedColumn {
                  columnName
                  columnType
                  columnDatatypeResults {
                    dataType {
                      id
                      name
                      analyzerType
                      __typename
                    }
                    result {
                      id
                      totalHits
                      totalViolatedHits
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                columnResults {
                  ... on AnalyzedColumn {
                    columnName
                    columnType
                    columnDatatypeResults {
                      dataType {
                        id
                        name
                        analyzerType
                        __typename
                      }
                      result {
                        id
                        totalHits
                        totalViolatedHits
                        __typename
                      }
                      __typename
                    }
                    __typename
                  }
                  columnResults {
                    ... on AnalyzedColumn {
                      columnName
                      columnType
                      columnDatatypeResults {
                        dataType {
                          id
                          name
                          analyzerType
                          __typename
                        }
                        result {
                          id
                          totalHits
                          totalViolatedHits
                          __typename
                        }
                        __typename
                      }
                      __typename
                    }
                    columnResults {
                      ... on AnalyzedColumn {
                        columnName
                        columnType
                        columnDatatypeResults {
                          dataType {
                            id
                            name
                            analyzerType
                            __typename
                          }
                          result {
                            id
                            totalHits
                            totalViolatedHits
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
        __typename
      }
      __typename
    }
    count
    __typename
  }
}'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.fileSchemaResults.nodes
} ### Get-FileDetails

###### FUNCTIONS - END ######

Write-Host "Getting a list of all Salesforce objects with sensitive hits..."
$sfdcList = @()
$afterCursor = ''
do {
  $sfdcInventory = Get-SensitiveSalesforceObjects -afterCursor $afterCursor
  $sfdcList += $sfdcInventory.edges.node
  Write-Host "Found $($sfdcList.count) objects..."
  $afterCursor = $sfdcInventory.pageInfo.endCursor
} while ($sfdcInventory.pageInfo.hasNextPage)
Write-Host "Found $($sfdcList.count) Salesforce objects with sensitive hits in Rubrik" -ForegroundColor Green

$count = 0
$totalCount = $sfdcList.count

foreach ($obj in $sfdcList) {
  $count++
  Write-Host "[$count/$totalCount] Getting details for object: $($obj.assetMetadata.name)"
  # Get object level details
  $objDetail = Get-SensitiveDetails -objectID $obj.id -snapshotID $obj.snapshotFid

  # Get the file detail
  $fileDetail = Get-FileDetails -objectID $obj.id -snapshotID $obj.snapshotFid -path $objDetail.stdPath

  $fieldInfo = [PSCustomObject]@{}

  foreach ($i in $fileDetail) {
    $joinHits = $i.columnDatatypeResults | ForEach-Object {
      "$($_.DataType.Name): $($_.result.TotalHits)"
    }
    $singleHits = $joinHits -join ", "
    $fieldInfo | Add-Member -MemberType NoteProperty -Name $i.columnName -Value $singleHits
  }

  $obj | Add-Member -MemberType NoteProperty -Name "FieldInfo" -Value $fieldInfo -Force
}

# Process the results
$resultList = @()

$uniqueFields = $sfdcList |
    ForEach-Object { $_.FieldInfo.PSObject.Properties.Name } |   # Extract all keys in FieldInfo
    Select-Object -Unique                    # Get unique keys

foreach ($i in $sfdcList) {
  $res = [PSCustomObject]@{
    Name = $i.assetMetadata.name
    ID = $i.id
    Hits = $singleHits
  }
  foreach ($unique in $uniqueFields) {
    $res | Add-Member -MemberType NoteProperty -Name $unique -Value "" -Force
  }
  foreach ($getKey in $i.fieldInfo.PSObject.Properties.Name) {
    $res.$getKey = $i.FieldInfo.$getKey
  }
  $resultList += $res
}

$resultList | Export-Csv -Path $csvOutput -NoTypeInformation
Write-Host "Exported results to CSV file: $csvOutput" -ForegroundColor Green