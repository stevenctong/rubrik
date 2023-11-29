# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will generate a list of Rubrik Windows Volume Group info.

.DESCRIPTION
This script will generate a list of Rubrik Windows Volume Group info.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/20/23

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-RubrikVolumes.ps1
Runs the script generate a list of all Windows Volume Groups.

#>

### Variables section - please fill out as needed

# param (
#   [CmdletBinding()]
#
#   # Filename of CSV to output
#   [Parameter(Mandatory=$false)]
#   [string]$csvOutput = ''
# )

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

# Define the capacity metric conversions
$GB = 1000000000
$GiB = 1073741824
$TB = 1000000000000
$TiB = 1099511627776

# Set which capacity metric to use
$capacityMetric = $GB
$capacityDisplay = 'GB'

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

# CSV file info
$csvOutput = "./rubrik_wvg_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"


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

# Get Volume Groups list
Function Get-VolumeGroups {
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
      }
      @{
        "field" = "IS_REPLICATED"
        "texts" = @(
          "false"
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "childFilter" = @(
      @{
        "field" = "IS_GHOST"
        "texts" = @(
          "false"
        )
      }
    )
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query (`$first: Int!, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]!, `$childFilter: [Filter!]) {
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
        cluster {
          id
          name
        }
        isArchived
        effectiveSlaDomain {
          id
          name
        }
        primaryClusterLocation {
          id
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
        physicalChildConnection(typeFilter: [VolumeGroup], filter: `$childFilter) {
          count
          edges {
            node {
              id
              name
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
              primaryClusterLocation {
                id
                __typename
              }
              ... on VolumeGroup {
                isRelic
                volumes
                replicatedObjects {
                  cluster {
                    id
                    name
                  }
                }
              }
            }
          }
        }
      }
    }
    pageInfo {
      endCursor
      startCursor
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
  $vgList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $vgList.data.physicalHosts
}  ### Function Get-VolumeGroups

Write-Host "Getting list of Windows Volume Group hosts" -foregroundcolor green
$vgList = @()
$objCount = 0
$afterCursor = ''
do {
  $vgs = Get-VolumeGroups -afterCursor $afterCursor
  $objCount += $vgs.count
  $vgList += $vgs.edges.node
  $afterCursor = $vgs.pageInfo.endCursor
  Write-Host "$objCount objects found so far..." -foregroundcolor green
} while ($vgs.pageInfo.hasNextPage)

Write-Host "$objCount total objects found" -foregroundcolor green

# List of volumes
$vgFinalList = @()

# Loop through host to build a list of volumes
foreach ($vgHost in $vgList) {
  foreach ($vgHostVolume in $vgHost.hostVolumes) {
    $vgInfo = [PSCustomObject] @{
      "Cluster" = $vgHost.cluster.name
      "Host" = $vgHost.name
      "MountPoint" = $vgHostVolume.mountPoints[0]
      "Size" = $vgHostVolume.size
      "Size$capacityDisplay" = [math]::Round($vgHostVolume.size / $capacityMetric, 3)
      "OS" = $vgHost.osName
      "SLA" = $vgHost.effectiveSlaDomain.name
      "Type" = $vgHostVolume.fileSystemType
      "UID" = $vgHost.id
    }
  }
  $vgFinalList += $vgInfo
}

# Export the list to a CSV file
$vgFinalList | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput" -foregroundcolor green

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
