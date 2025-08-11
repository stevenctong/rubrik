# https://www.rubrik.com/api
<#
.SYNOPSIS
This script perform a restore of an entire bucket or specific prefixes / files
from a source S3 bucket to a targt S3 bucket.

.DESCRIPTION
This script perform a restore of an entire bucket or specific prefixes / files
from a source S3 bucket to a targt S3 bucket.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/10/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

.EXAMPLE
./Get-Restore-AWS_S3.ps1 -sourceAccount 'Account S' -sourceBucket 'Bucket S'
  -targetAccount 'Account T' -targetBucket 'Bucket T'
  -restoreDateUTC '2025-08-08 20:00' -restoreBucket $true
  -restoreType 'Export'
Selects the snapshot right before the provided date and restores the entire source bucket to the target bucket.

.EXAMPLE
./Get-Restore-AWS_S3.ps1 -sourceAccount 'Account S' -sourceBucket 'Bucket S'
  -targetAccount 'Account T' -targetBucket 'Bucket T'
  -restoreDateUTC '2025-08-08 20:00' -restorePrefixFiles 'Source S/Files,Source S/Data'
  -restoreType 'Export'
Selects the snapshot right before the provided date and restores the comma separated
list of prefixes / files to the target bucket.

#>

param (
  [CmdletBinding()]
  # Source AWS Account to restore from
  [Parameter(Mandatory=$false)]
  [string]$sourceAccount = '',
  # Source S3 bucket name to restore from
  [Parameter(Mandatory=$false)]
  [string]$sourceBucket = '',
  # Target AWS Account to restore to
  [Parameter(Mandatory=$false)]
  [string]$targetAccount = '',
  # Target AWS Bucket to restore to
  [Parameter(Mandatory=$false)]
  [string]$targetBucket = '',
  # Restore type - 'Export' or 'InPlaceRecovery'
  [Parameter(Mandatory=$false)]
  [string]$restoreType = '',
  # Restore granularity - Set to $true to restore entire bucket
  [Parameter(Mandatory=$false)]
  [bool]$restoreBucket = $false,
  # Restore granularity - Specify prefixes and/or files to restore, comma separated lsit
  [Parameter(Mandatory=$false)]
  [string]$restorePrefixFiles = '',
  # Restore date - "YYYY-MM-DD HH:MM" format, get the closest snapshot before this date
  [Parameter(Mandatory=$false)]
  [string]$restoreDateUTC = ''
)

### Variables section - please fill out as needed

# File location of the RSC service account json
$serviceAccountPath = "./rsc-gaia.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# SMTP configuration if you want to send an email at the end of this script
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "Rubrik Object Capacity Summary - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
# $sendEmail = $false

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

##### FUNCTIONS - BEGIN #####

# Get AWS S3 buckets
Function Get-AWSS3Buckets {
  $variables = @{
    "objectTypeFilter" = "AWS_NATIVE_S3_BUCKET"
    "includeSecurityMetadata" = $true
    "first" = 100
    "filter" = @(
      @{
        "texts" = @(
          "false"
        )
        "field" = "IS_RELIC"
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "includeRscNativeObjectPendingSla" = $true
  }
  $query = 'query AwsInventoryTableQuery($objectTypeFilter: HierarchyObjectTypeEnum!, $first: Int, $after: String, $sortBy: HierarchySortByField, $sortOrder: SortOrder, $filter: [Filter!]!, $includeSecurityMetadata: Boolean!, $includeRscNativeObjectPendingSla: Boolean!) {
    awsNativeRoot {
      objectTypeDescendantConnection(
        objectTypeFilter: $objectTypeFilter
        first: $first
        after: $after
        sortBy: $sortBy
        sortOrder: $sortOrder
        filter: $filter
        includeSecurityMetadata: $includeSecurityMetadata
      ) {
        edges {
          cursor
          node {
            id
            name
            isRelic
            region
            cloudNativeId
            nativeName
            logicalPath {
              name
              fid
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
                rscNativeObjectPendingSla @include(if: $includeRscNativeObjectPendingSla) {
                  id
                  name
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
              securityMetadata {
                isLaminarEnabled
                sensitivityStatus
                highSensitiveHits
                mediumSensitiveHits
                lowSensitiveHits
                dataTypeResults {
                  id
                  name
                  totalHits
                  totalViolatedHits
                  __typename
                }
                __typename
              }
              __typename
            }
            ... on AwsNativeS3Bucket {
              creationTime
              isExocomputeConfigured
              numberOfObjects
              bucketSizeBytes
              isOnboarding
              awsNativeAccountDetails {
                id
                name
                status
                __typename
              }
              __typename
            }
            ... on AwsNativeDynamoDbTable {
              authorizedOperations
              awsNativeAccountDetails {
                id
                name
                status
                enabledFeatures {
                  featureName
                  lastRefreshedAt
                  status
                  __typename
                }
                __typename
              }
              isRelic
              isAwsContinuousBackupEnabled
              isExocomputeConfigured
              nonBackupRegionNames
              tableSizeBytes
              __typename
            }
            __typename
          }
          __typename
        }
        pageInfo {
          endCursor
          hasNextPage
          hasPreviousPage
          startCursor
          __typename
        }
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
  return $result.data.awsNativeRoot.objectTypeDescendantConnection.edges.node
}  ### Function Get-AWSS3Buckets

# Get recovery points (snapshots) available for a S3 bucket
Function Get-S3Snapshots {
  param (
    [CmdletBinding()]
    # Source S3 Bucket (workload) ID
    [Parameter(Mandatory=$false)]
    [string]$bucketID = ''
  )
  $variables = @{
    "isLegalHoldThroughRbacEnabled" = $true
    "snappableId" = $bucketID
    "first" = 200
    "sortBy" = "CREATION_TIME"
    "sortOrder" ="DESC"
    "includeSapHanaAppMetadata" = $false
    "includeDb2AppMetadata" = $false
    "snapshotFilter" = @(
      @{
        "field" = "SNAPSHOT_TYPE"
        "typeFilters" = @()
      }
    )
    "timeRange"= $null
  }
  $query = 'query SnapshotsListSingleQuery($snappableId: String!, $first: Int, $after: String, $snapshotFilter: [SnapshotQueryFilterInput!], $sortBy: SnapshotQuerySortByField, $sortOrder: SortOrder, $timeRange: TimeRangeInput, $includeSapHanaAppMetadata: Boolean!, $includeDb2AppMetadata: Boolean!, $isLegalHoldThroughRbacEnabled: Boolean = false) {
    snapshotsListConnection: snapshotOfASnappableConnection(
      workloadId: $snappableId
      first: $first
      after: $after
      snapshotFilter: $snapshotFilter
      sortBy: $sortBy
      sortOrder: $sortOrder
      timeRange: $timeRange
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
                isSnapshotOnLegalHold @include(if: $isLegalHoldThroughRbacEnabled)
                __typename
              }
              localInfo {
                name
                isExpirationDateCalculated
                expirationTime
                isSnapshotOnLegalHold @include(if: $isLegalHoldThroughRbacEnabled)
                __typename
              }
              replicationInfos {
                name
                isExpirationDateCalculated
                expirationTime
                locationId
                isExpirationInformationUnavailable
                isSnapshotOnLegalHold @include(if: $isLegalHoldThroughRbacEnabled)
                __typename
              }
              __typename
            }
            sapHanaAppMetadata @include(if: $includeSapHanaAppMetadata) {
              backupId
              backupPrefix
              snapshotType
              files {
                backupFileSizeInBytes
                __typename
              }
              __typename
            }
            db2AppMetadata @include(if: $includeDb2AppMetadata) {
              backupId
              snapshotType
              files {
                backupFileSizeInBytes
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
            archivalLocationId
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
            isRetentionLocked
            snapshotRetentionInfo {
              isCustomRetentionApplied
              localInfo {
                locationName
                expirationTime
                isExpirationDateCalculated
                isSnapshotPresent
                __typename
              }
              archivalInfos {
                locationName
                expirationTime
                isExpirationDateCalculated
                isSnapshotPresent
                __typename
              }
              replicationInfos {
                locationName
                expirationTime
                isExpirationDateCalculated
                isSnapshotPresent
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
        endCursor
        hasNextPage
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
  return $result.data.snapshotsListConnection.edges.node
}  ### Function Get-S3Snapshots


# Get AWS Accounts for recovery
Function Get-AWSAccounts {
  $variables = @{
    "awsCloudAccountsArg" = @{
      "feature" = "CLOUD_NATIVE_S3_PROTECTION"
      "statusFilters" = @()
    }
  }
  $query = 'query AwsRecoverSnapshotCloudAccountsListQuery($awsCloudAccountsArg: AwsCloudAccountsWithFeaturesInput!) {
    allAwsCloudAccountsFeaturesWithExoConfigs(awsCloudAccountsArg: $awsCloudAccountsArg) {
      awsCloudAccount {
        id
        accountName
        cloudType
        __typename
      }
      featureDetails {
        feature
        status
        awsRegions
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
  return $result.data.allAwsCloudAccountsFeaturesWithExoConfigs.awscloudaccount
}  ### Function Get-AWSAccounts

# Get AWS Buckets filetered by Account for recovery
Function Get-AWSRecoveryBuckets {
  param (
    [CmdletBinding()]
    # AWS Account ID
    [Parameter(Mandatory=$false)]
    [string]$accountID = ''
  )
  $variables = @{
    "accountId" = $accountID
  }
  $query = 'query AwsS3BucketNameListQuery($accountId: UUID!, $region: AwsNativeRegion) {
    allS3BucketsDetailsFromAws(awsAccountRubrikId: $accountId, region: $region) {
      arn
      name
      region
      regionEnum
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.allS3BucketsDetailsFromAws
}  ### Function Get-AWSRecoveryBuckets

# Recover via Export to another S3 bucket
Function Export-S3 {
  param (
    [CmdletBinding()]
    # Restore params - if bucket, prefix, or files
    [Parameter(Mandatory=$false)]
    [hashtable]$exportInput = ''
  )
  $variables = @{
    "input" = $exportInput
  }
  $query = 'mutation AwsS3RecoveryMutation($input: StartRecoverS3SnapshotJobInput!) {
    startRecoverS3SnapshotJob(input: $input) {
      jobId
      error
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Export-S3


##### FUNCTIONS - END #####

# . ./Get-Restore-AWS_S3.ps1 -sourceAccount 'Rubrik Gaia Native' -sourceBucket 'rubrik-gaia-s3-native' `
#   -targetAccount 'Rubrik Gaia Native' -targetBucket 'rubrik-gaia-s3-native-export-target' `
#   -restoreDateUTC '2025-08-08 20:00' -restorePrefixFiles 'rubrik-gaia-s3-native/Finance Department/,rubrik-gaia-s3-native/HR Department/' `
#   -restoreType 'Export'

# $restoreDateUTC = "2025-08-08 20:00"
# $sourceAccount = 'Rubrik Gaia Native'
# $sourceBucket = 'rubrik-gaia-s3-native'
# $targetAccount = 'Rubrik Gaia Native'
# $targetBucket = 'rubrik-gaia-s3-native-export-target'
# $restorePrefixFiles = 'rubrik-gaia-s3-native/Finance Department/,rubrik-gaia-s3-native/HR Department/'

Write-Host "Getting AWS S3 buckets..."
$s3List = Get-AWSS3Buckets

try {
  $sourceWorkload = $s3List | Where { $_.name -eq $sourceBucket -and
    $_.awsNativeAccountDetails.name -eq $sourceAccount }
  if ($sourceWorkload.count -eq 1) {
    $sourceWorkloadID = $sourceWorkload.id
  }
} catch {
  Write-Error "Error getting a unique source bucket ID..."
}
Write-Host "Found Source Account ($sourceAccount), Source Bucket ($sourceBucket): $sourceWorkloadID"
Write-Host ""

Write-Host "Getting snapshots (recovery points)..."
$sourceSnapshots = Get-S3Snapshots -bucketID $sourceWorkloadID

# Get the closest snapshot before this recovery date
$restoreDateTimeUTC = [datetime]$restoreDateUTC

$selectedSnapshot = $null

# Find the restore point that is right before the $restoreDateUTC
foreach ($d in $sourceSnapshots) {
  if ($d.date -lt $restoreDateTimeUTC) {
    if ($selectedSnapshot -eq $null) {
      $selectedSnapshot = $d
    }
  }
}

$sourceSnapshotID = $($selectedSnapshot.id)

Write-Host "Found snapshot from: $($selectedSnapshot.date) right before the provided restore date: $restoreDateUTC"
Write-Host "Snapshot ID: $sourceSnapshotID"
Write-Host ""

if ($restoreType -eq 'Export') {
  # Find target account ID and bucket ID
  $awsAccounts = Get-AWSAccounts
  $targetAccountID = $($awsAccounts | Where { $_.accountName -eq $targetAccount }).id
  $recoveryBuckets = Get-AWSRecoveryBuckets -accountID $targetAccountID
  $targetBucketDetail = $recoveryBuckets | Where { $_.name -eq $targetBucket }
  # If doing a full bucket restore
  if ($restoreBucket -eq $true) {
    $exportInput = @{
      "destinationBucketArn" = $($targetBucketDetail.arn)
      "objectKeys" = @()
      "shouldRecoverFullBucket" = $true
      "snapshotId" = $sourceSnapshotID
      "workloadId" = $sourceWorkloadID
      "targetAwsAccountRubrikId" = $targetAcountID
    }
    Write-Host "Initiating export to restore entire bucket for source: $($sourceWorkload.Name)"
    Write-Host "Target: $($targetBucketDetail.name), $($targetBucketDetail.region)"
    $result = Export-S3 -ExportInput $exportInput
    $result.data
  }
  if ($restorePrefixFiles -ne '') {
    $restoreArray = $restorePrefixFiles -split ','
    $exportInput = @{
      "destinationBucketArn" = $($targetBucketDetail.arn)
      "objectKeys" = $restoreArray
      "shouldRecoverFullBucket" = $false
      "snapshotId" = $sourceSnapshotID
      "workloadId" = $sourceWorkloadID
      "targetAwsAccountRubrikId" = $targetAccountID
    }
    Write-Host "Initiating export to restore: $restorePrefixFiles"
    Write-Host "Target: $($targetBucketDetail.name), $($targetBucketDetail.region)"
    $result = Export-S3 -ExportInput $exportInput
    $result.data
  }
}
