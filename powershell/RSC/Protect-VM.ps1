<#
.SYNOPSIS
This script will assign a SLA to VMs.

.DESCRIPTION
This script will assign a SLA to VMs.
The current script is hard coded to protect all VMs in a SLA.
Will generalize it later.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/26/23

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Protect-VM.ps1
Protect the VMs hard coded in the script by SLA.

#>


# param (
#   [CmdletBinding()]
#   # Optional Paramter
#   # [Parameter(Mandatory=$false)]
#   # [string]$optionalParamter
# )

$date = Get-Date

# CSV file output
$csvOutput = "./file_$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

$retries = 3

# Set to $true to send out email at the end of this script
$sendEmail = $false

###### RUBRIK AUTHENTICATION - BEGIN ######

$serviceAccountPath = "./rsc-service-account-rr.json"

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
    # VM string to filter by
    [Parameter(Mandatory=$false)]
    [string]$vmString = 'cdp-vm',
    # Cluster ID to filter by
    [Parameter(Mandatory=$false)]
    [string]$clusterID = '3bc43be7-00ca-4ed8-ba13-cef249d337fa',
    # SLA ID to filter by
    [Parameter(Mandatory=$false)]
    [string]$slaID = 'a60cb991-f6ea-45dd-ba13-048bd909c95b'
  )
  $variables = @{
    "first" = 50
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
        "field" = "NAME"
        "texts" = @(
          $vmString
        )
      },
      @{
        "field" = "CLUSTER_ID"
        "texts" = @(
          $clusterID
        )
      },
      @{
        "field" = "EFFECTIVE_SLA_WITH_RETENTION_SLA"
        "texts" = @(
          $slaID
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
  $query = "query (`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereVmNewConnection(filter: `$filter, first: `$first, after: `$after, sortBy: `$sortBy, sortOrder: `$sortOrder) {
      edges {
        cursor
        node {
          id
          name
          objectType
          cluster {
            id
            name
            version
            status
            __typename
          }
          effectiveSlaDomain {
            id
            name
            __typename
          }
          __typename
          isRelic
          primaryClusterLocation {
            id
            name
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
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $vmList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.vSphereVmNewConnection.edges.node
  return $vmList
}  ### Function VMList

# Protect a VM with a SLA
Function Protect-VM {
  param (
    [CmdletBinding()]
    # List of VM IDs to assign SLA to
    [Parameter(Mandatory=$true)]
    [array]$vmIDList,
    # SLA ID to use for the assignment
    [Parameter(Mandatory=$false)]
    [array]$slaID = '1fc9207e-0db0-46de-9088-6e23905c7d7c'
  )
  $variables = @{
    "userNote" = ""
    "globalExistingSnapshotRetention" = $null
    "globalSlaAssignType" = "protectWithSlaId"
    "globalSlaOptionalFid" = "1fc9207e-0db0-46de-9088-6e23905c7d7c"
    "objectIds" = $vmIDList
    "shouldApplyToExistingSnapshots" = $true
    "shouldApplyToNonPolicySnapshots" = $false
  }
  $payload = @{
    "query" = "mutation (`$globalExistingSnapshotRetention: GlobalExistingSnapshotRetention,
      `$globalSlaOptionalFid: UUID, `$globalSlaAssignType: SlaAssignTypeEnum!,
      `$objectIds: [UUID!]!, `$applicableSnappableTypes: [WorkloadLevelHierarchy!],
      `$shouldApplyToExistingSnapshots: Boolean, `$shouldApplyToNonPolicySnapshots: Boolean,
      `$userNote: String)
    {
      assignSlasForSnappableHierarchies(globalExistingSnapshotRetention: `$globalExistingSnapshotRetention,
      globalSlaOptionalFid: `$globalSlaOptionalFid, globalSlaAssignType: `$globalSlaAssignType,
      objectIds: `$objectIds, applicableSnappableTypes: `$applicableSnappableTypes,
      shouldApplyToExistingSnapshots: `$shouldApplyToExistingSnapshots,
      shouldApplyToNonPolicySnapshots: `$shouldApplyToNonPolicySnapshots,
      userNote: `$userNote)
      {
        success
        __typename
      }
    }"
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response
}  ### Function Protect-VM

do {
  $vmList = Get-VMList
  $vmArray = @()
  $vmArray += $vmList[0].id
  Write-Host "Protecting: $($vmList[0].name), $vmArray"
  $resp = Protect-VM -vmIDList $vmArray
  $resp.data
  Start-Sleep -seconds 300
} while ($vmList.count -gt 1)
