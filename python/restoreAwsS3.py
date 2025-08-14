

import argparse
import os
import json
import requests
import sys
from datetime import datetime

# Command-line arguments parsing
def parse_arguments():
    parser = argparse.ArgumentParser(description="Rubrik Object Capacity Summary Script")
    parser.add_argument("--sourceAccount", type=str, default='', help="Source AWS Account to restore from")
    parser.add_argument("--sourceBucket", type=str, default='', help="Source S3 bucket name to restore from")
    parser.add_argument("--targetAccount", type=str, default='', help="Target AWS Account to restore to")
    parser.add_argument("--targetBucket", type=str, default='', help="Target AWS Bucket to restore to")
    parser.add_argument("--restoreType", type=str, default='', help="Restore type - 'Export' or 'InPlaceRecovery'")
    parser.add_argument("--restoreBucket", action="store_true", help="Set to True to restore the entire bucket")
    parser.add_argument("--restorePrefixFiles", type=str, default='', help="Specify prefixes/files to restore (comma-separated list)")
    parser.add_argument("--restoreDateUTC", type=str, default='', help='Restore date in "YYYY-MM-DD HH:MM" format')
    return parser.parse_args()

# Load the Rubrik Service Account JSON file
def load_service_account(service_account_path):
    print(f"Info: Attempting to read the Service Account file located at {service_account_path}")
    try:
        with open(service_account_path, "r") as file:
            service_account_data = json.load(file)
    except FileNotFoundError:
        raise FileNotFoundError(f"The Service Account JSON secret file was not found. Ensure the file is located at {service_account_path}.")
    except Exception as e:
        raise Exception(f"Error occurred while reading the Service Account JSON: {str(e)}")
    # Check for missing required fields
    required_fields = ["client_id", "client_secret", "access_token_uri"]
    missing_fields = [field for field in required_fields if field not in service_account_data]
    if missing_fields:
        raise Exception(f"The Service Account JSON secret file is missing the required parameters: {missing_fields}")
    return service_account_data

# Authenticate to Rubrik's GraphQL API
def authenticate_to_rubrik(service_account_data):
    payload = {
        "grant_type": "client_credentials",
        "client_id": service_account_data["client_id"],
        "client_secret": service_account_data["client_secret"]
    }
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    print("Connecting to the RSC GraphQL API using the Service Account JSON file.")
    response = requests.post(service_account_data["access_token_uri"], json=payload, headers=headers)
    response.raise_for_status()  # Raise an HTTPError on a bad response
    token_data = response.json()
    rubrik_url = service_account_data["access_token_uri"].replace("/api/client_token", "")
    rubrik_connection = {
        "accessToken": token_data["access_token"],
        "rubrikURL": rubrik_url
    }
    print(f"Successfully connected to: {rubrik_url}")
    return rubrik_connection

def get_aws_s3_buckets(endpoint, headers):
    variables = {
        "objectTypeFilter": "AWS_NATIVE_S3_BUCKET",
        "includeSecurityMetadata": True,
        "first": 100,
        "filter": [
            {
                "texts": ["false"],
                "field": "IS_RELIC"
            }
        ],
        "sortBy": "NAME",
        "sortOrder": "ASC",
        "includeRscNativeObjectPendingSla": True
    }
    query = """
        query AwsInventoryTableQuery($objectTypeFilter: HierarchyObjectTypeEnum!, $first: Int, $after: String, $sortBy: HierarchySortByField, $sortOrder: SortOrder, $filter: [Filter!]!, $includeSecurityMetadata: Boolean!, $includeRscNativeObjectPendingSla: Boolean!) {
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
      }
    """
    response = requests.post(endpoint, json={"query": query, "variables": variables}, headers=headers)
    if response.status_code == 200:
        return response.json()
    return {"error": response.text, "status_code": response.status_code}

def get_s3_snapshots(endpoint, headers, bucket_id):
    variables = {
        "isLegalHoldThroughRbacEnabled": True,
        "snappableId": bucket_id,
        "first": 200,
        "sortBy": "CREATION_TIME",
        "sortOrder": "DESC",
        "includeSapHanaAppMetadata": False,
        "includeDb2AppMetadata": False,
        "snapshotFilter": [
            {
                "field": "SNAPSHOT_TYPE",
                "typeFilters": []
            }
        ],
        "timeRange": None
    }
    query = """
        query SnapshotsListSingleQuery($snappableId: String!, $first: Int, $after: String, $snapshotFilter: [SnapshotQueryFilterInput!], $sortBy: SnapshotQuerySortByField, $sortOrder: SortOrder, $timeRange: TimeRangeInput, $includeSapHanaAppMetadata: Boolean!, $includeDb2AppMetadata: Boolean!, $isLegalHoldThroughRbacEnabled: Boolean = false) {
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
      }
    """
    response = requests.post(endpoint, json={"query": query, "variables": variables}, headers=headers)
    if response.status_code == 200:
        return response.json()
    return {"error": response.text, "status_code": response.status_code}

def get_aws_accounts(endpoint, headers):
    variables = {
        "awsCloudAccountsArg": {
            "feature": "CLOUD_NATIVE_S3_PROTECTION",
            "statusFilters": []
        }
    }
    query = """
    query AwsRecoverSnapshotCloudAccountsListQuery($awsCloudAccountsArg: AwsCloudAccountsWithFeaturesInput!) {
        allAwsCloudAccountsFeaturesWithExoConfigs(awsCloudAccountsArg: $awsCloudAccountsArg) {
            awsCloudAccount {
                id
                accountName
                cloudType
            }
            featureDetails {
                feature
                status
                awsRegions
            }
        }
    }
    """
    response = requests.post(endpoint, json={"query": query, "variables": variables}, headers=headers)
    if response.status_code == 200:
        return response.json()
    return {"error": response.text, "status_code": response.status_code}

def get_aws_recovery_buckets(endpoint, headers, account_id):
    variables = {
        "accountId": account_id
    }
    query = """
    query AwsS3BucketNameListQuery($accountId: UUID!, $region: AwsNativeRegion) {
        allS3BucketsDetailsFromAws(awsAccountRubrikId: $accountId, region: $region) {
            arn
            name
            region
            regionEnum
        }
    }
    """
    response = requests.post(endpoint, json={"query": query, "variables": variables}, headers=headers)
    if response.status_code == 200:
        return response.json()
    return {"error": response.text, "status_code": response.status_code}

def export_s3(endpoint, headers, export_input):
    variables = {
        "input": export_input
    }
    query = """
    mutation AwsS3RecoveryMutation($input: StartRecoverS3SnapshotJobInput!) {
        startRecoverS3SnapshotJob(input: $input) {
            jobId
            error
        }
    }
    """
    response = requests.post(endpoint, json={"query": query, "variables": variables}, headers=headers)
    if response.status_code == 200:
        return response.json()
    return {"error": response.text, "status_code": response.status_code}

def is_null_or_whitespace(value):
    """Check if a string is null, empty, or consists only of whitespace."""
    return value is None or str(value).strip() == ""


def main():
    # Parse command-line arguments
    args = parse_arguments()

    ### For testing...
    # class Args:
    #     restoreDateUTC = "2025-08-08 20:00"
    #     sourceAccount = "Rubrik Gaia Native"
    #     sourceBucket = "rubrik-gaia-s3-native"
    #     targetAccount = "Rubrik Gaia Native"
    #     targetBucket = "rubrik-gaia-s3-native-export-target"
    #     restoreType = "Export"
    #     restoreBucket = False
    #     restorePrefixFiles = "rubrik-gaia-s3-native/Finance Department/,rubrik-gaia-s3-native/HR Department/"
    # args = Args()

    if is_null_or_whitespace(args.sourceAccount) or is_null_or_whitespace(args.sourceBucket):
        print("Error: Source account and/or source bucket cannot be empty. Exiting...", file=sys.stderr)
        sys.exit(1)

    if is_null_or_whitespace(args.restoreType) or args.restoreType not in ["Export", "InPlaceRecovery"]:
        print("Error: RestoreType should either be 'Export' or 'InPlaceRecovery'. Exiting...", file=sys.stderr)
        sys.exit(1)

    # File path to RSC service account JSON
    service_account_path = "./rsc-gaia.json"
    # Get the current UTC date and time
    utc_date = datetime.utcnow()
    # Load the service account JSON file
    service_account_data = load_service_account(service_account_path)
    # Authenticate to Rubrik API
    rubrik_connection = authenticate_to_rubrik(service_account_data)
    # Rubrik GraphQL API URL and headers
    endpoint = f"{rubrik_connection['rubrikURL']}/api/graphql"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": f"Bearer {rubrik_connection['accessToken']}"
    }

    print("\nGetting AWS S3 buckets...")
    try:
        s3_list_response = get_aws_s3_buckets(endpoint, headers)
        if "data" not in s3_list_response or "awsNativeRoot" not in s3_list_response["data"]:
            raise ValueError("Invalid response structure from get_aws_s3_buckets()")
        s3_list = s3_list_response["data"]["awsNativeRoot"]["objectTypeDescendantConnection"]["edges"]
    except Exception as e:
        print(f"Error fetching S3 buckets: {str(e)}", file=sys.stderr)
        sys.exit(1)
        # print(s3_list)
        source_bucket_detail = next(
            (bucket["node"] for bucket in s3_list if bucket["node"]["name"] == args.sourceBucket and bucket["node"]["awsNativeAccountDetails"]["name"] == args.sourceAccount),
            None  # Return None if no match is found
        )

    if source_bucket_detail:
        # If a unique bucket is found, extract the ID and ARN
        source_bucket_id = source_bucket_detail["id"]
        source_bucket_arn = source_bucket_detail["cloudNativeId"]
        print(f"Found Source Account ({args.sourceAccount}), Source Bucket ({args.sourceBucket})")
        print(f"With ID: {source_bucket_id}, ARN: {source_bucket_arn}\n")
    else:
        raise ValueError("No matching bucket found. Exiting...")

    print("Getting snapshots (recovery points)...")
    source_snapshots = get_s3_snapshots(endpoint, headers, bucket_id=source_bucket_id)
    restore_date_utc = datetime.strptime(args.restoreDateUTC, "%Y-%m-%d %H:%M")
    # Filter for the closest snapshot before the restore date
    selected_snapshot = None

    for snapshot in source_snapshots['data']['snapshotsListConnection']['edges']:
        snapshot_date = datetime.strptime(snapshot["node"]["date"], "%Y-%m-%dT%H:%M:%S.%fZ")  # Parse snapshot date
        if snapshot_date < restore_date_utc:  # Check if snapshot is before the restore date
            if selected_snapshot is None or snapshot_date > datetime.strptime(selected_snapshot["node"]["date"], "%Y-%m-%dT%H:%M:%S.%fZ"):
                # If no snapshot is selected, or if it's closer to the restore date, update selected_snapshot
                selected_snapshot = snapshot

    # Extract snapshot ID
    source_snapshot_id = selected_snapshot["node"]["id"]  # Access ID from the selected snapshot

    # Print information about the selected snapshot
    print(f"Found snapshot from: {selected_snapshot['node']['date']} right before the provided restore date: {args.restoreDateUTC}")
    print(f"Snapshot ID: {source_snapshot_id}\n")

    # Initialize destinationBucketArn to None (equivalent to `$null`)
    destination_bucket_arn = None

    # Check restoreType and assign destinationBucketArn accordingly
    if args.restoreType == "InPlaceRecovery":
        destination_bucket_arn = source_bucket_arn  # Use sourceBucketArn

    # Check restoreType and assign destinationBucketArn accordingly
    if args.restoreType == "Export":
        print("Finding target account ID...")
        aws_accounts_response = get_aws_accounts(endpoint, headers)
        aws_accounts = aws_accounts_response["data"]["allAwsCloudAccountsFeaturesWithExoConfigs"]
        target_account_id = next(
            (account["awsCloudAccount"]["id"] for account in aws_accounts if account["awsCloudAccount"]["accountName"] == args.targetAccount),
            None  # Default to None if no match is found
        )
        if not target_account_id:
            raise ValueError(f"Target account '{args.targetAccount}' not found.")
        # Fetch recovery buckets for the target account
        print("Fetching recovery buckets...")
        recovery_buckets_response = get_aws_recovery_buckets(endpoint, headers, account_id=target_account_id)
        if "data" not in recovery_buckets_response or "allS3BucketsDetailsFromAws" not in recovery_buckets_response["data"]:
            raise ValueError("Invalid response structure from get_aws_recovery_buckets()")
        recovery_buckets = recovery_buckets_response["data"]["allS3BucketsDetailsFromAws"]
        # Find the target bucket in recovery buckets
        target_bucket_detail = next(
            (bucket for bucket in recovery_buckets if bucket["name"] == args.targetBucket),
            None
        )
        if not target_bucket_detail:
            raise ValueError(f"Target bucket '{args.targetBucket}' not found.")
        # Assign the destination bucket ARN
        destination_bucket_arn = target_bucket_detail["arn"]

    if args.restoreBucket:
        # Prepare the export input for a full bucket restore
        export_input = {
            "destinationBucketArn": destination_bucket_arn,
            "objectKeys": [],  # Empty list for full bucket restore
            "shouldRecoverFullBucket": True,
            "snapshotId": source_snapshot_id,
            "workloadId": source_bucket_id,
            "targetAwsAccountRubrikId": target_account_id,
        }
        print(f"Initiating export to restore entire bucket for source: {source_bucket_detail['name']}")
        print(f"Target: {target_bucket_detail['name']}, {target_bucket_detail['region']})"
        try:
            # Perform the export operation with the provided input
            export_response = export_s3(endpoint, headers, export_input)
            if "data" in export_response:
                print("Export Response Data:")
                print(export_response["data"])
            else:
                raise ValueError("Invalid response structure from export_s3().")
        except Exception as e:
            print(f"Error initiating export: {str(e)}", file=sys.stderr)
            sys.exit(1)

    if args.restorePrefixFiles != "":
        # Split restorePrefixFiles into a list (similar to PowerShell's -split)
        restore_array = args.restorePrefixFiles.split(",")  # Split by commas
        # Prepare the export input for prefix/file restore
        export_input = {
            "destinationBucketArn": destination_bucket_arn,
            "objectKeys": restore_array,  # Array of prefixes/files
            "shouldRecoverFullBucket": False,  # Not full bucket restore
            "snapshotId": source_snapshot_id,
            "workloadId": source_bucket_id,
            "targetAwsAccountRubrikId": target_account_id,
        }
        print(f"Initiating export to restore: {args.restorePrefixFiles}")
        print(f"Target: {target_bucket_detail['name']}, {target_bucket_detail['region']}")
        try:
            # Perform the export operation with the provided input
            export_response = export_s3(endpoint, headers, export_input)
            if "data" in export_response:
                print("Export Response Data:")
                print(export_response["data"])  # Output the data returned by the mutation
            else:
                raise ValueError("Invalid response structure from export_s3().")
        except Exception as e:
            print(f"Error initiating export: {str(e)}", file=sys.stderr)
            sys.exit(1)

if __name__ == "__main__":
    main()
