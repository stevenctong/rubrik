# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get the disk details for VMware and AHV VMs and export it to
a CSV. You can mark disks for exclusion and re-import the CSV to exclude the disks.

.DESCRIPTION
This script will get the disk details for VMware and AHV VMs and export it to
a CSV.

You can mark disks for exclusion and re-import the CSV to exclude the disks.
Use the 'setExclude' column.
- Set to 'TRUE' if you want to mark the disk for exclusion
- Set to 'FALSE' if you want to mark the disk for un-exclusion
- Leave blank to leave the current setting alone

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/30/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a custom role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-Set-vmDisks.ps1
Runs the script and outputs VMware and AHV disk info to a csv.

#>

### VARIABLES - START ###

# param (
#   [CmdletBinding()]
#   # Rubrik cluster name
#   [Parameter(Mandatory=$false)]
#   [string]$cluster = ''
# )


# File location of the RSC service account json
# $serviceAccountPath = "./rsc-service-account-rr.json"
$serviceAccountPath = "./svc.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV file info
$ahvCsvOutput = "./rubrik_ahv_disks-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$vmwareCsvOutput = "./rubrik_vmware_disks-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "Rubrik - " + $date.ToString("yyyy-MM-dd HH:MM")

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

# Get VMware list
Function Get-VMwareList {
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
        vsphereVirtualDisks {
          nodes {
            fileName
            fid
            deviceKey
            excludeFromSnapshots
            size
            virtualMachineId
            datastore {
              name
              id
            }
            datastoreFid
          }
        }
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
}  ### Function Get-VMwareList


# Get AHV list
Function Get-AHVList {
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
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query NutanixVirtualMachinesTableQuery(`$first: Int, `$after: String, `$filter: [Filter!], `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
  nutanixVms(
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
        vmDisks {
          label
          sizeInBytes
          vmDiskUuid
          uuid
          deviceType
          storageContainerId
          storageContainerName
          isSnapshottable
        }
        isRelic
        reportSnappable {
          archiveStorage
          physicalBytes
          __typename
        }
        physicalPath {
          fid
          name
          objectType
          __typename
        }
        snapshotConnection {
          count
          __typename
        }
        agentStatus {
          connectionStatus
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
          allOrgs {
            fullName
            __typename
          }
          __typename
        }
        slaPauseStatus
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
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.nutanixVms
}  ### Function Get-AHVList


###### FUNCTIONS - END ######

# Holds the CSV for AHV
$ahvCSV = @()

Write-Host "Getting a list of all AHV VMs" -foregroundcolor green
$ahvList = @()
$afterCursor = ''
do {
  $ahvInventory = Get-AHVList -afterCursor $afterCursor
  $ahvList += $ahvInventory.edges.node
  $afterCursor = $ahvInventory.pageInfo.endCursor
} while ($ahvInventory.pageInfo.hasNextPage)

Write-Host "Found $($ahvList.count) total AHV VMs" -foregroundcolor green

foreach ($ahvVM in $ahvList) {
  foreach ($ahvDisk in $($ahvVM.vmDisks)) {
    $ahvDetails = [PSCustomObject] @{
      "VM" = $ahvVM.name
      "ahvCluster" = $($ahvVM.physicalPath[0].name)
      "SLA" = $ahvVM.effectiveSlaDomain.name
      "Disk" = $ahvDisk.label
      "Size" = $ahvDisk.sizeInBytes
      "SizeGB" = $($ahvDisk.sizeInBytes / 1000 / 1000 / 1000)
      "SizeGiB" = $($ahvDisk.sizeInBytes / 1024 / 1024 / 1024)
      "vmID" = $ahvVM.id
      "vmDiskUuid" = $ahvDisk.vmDiskUuid
      "isSnapshottable" = $ahvDisk.isSnapshottable
      "setExclude" = ""
    }
    $ahvCSV += $ahvDetails
  }
}


# Holds the CSV for VMware
$vmwareCSV = @()

Write-Host "Getting a list of all VMware VMs" -foregroundcolor green
$vmwareList = @()
$afterCursor = ''
do {
  $vmwareInventory = Get-vmwareList -afterCursor $afterCursor
  $vmwareList += $vmwareInventory.edges.node
  $afterCursor = $vmwareInventory.pageInfo.endCursor
} while ($vmwareInventory.pageInfo.hasNextPage)

Write-Host "Found $($vmwareList.count) total VMware VMs" -foregroundcolor green

foreach ($vmwareVM in $vmwareList) {
  foreach ($vmwareDisk in $($vmwareVM.vsphereVirtualDisks.nodes)) {
    $vmwareDetails = [PSCustomObject] @{
      "VM" = $vmwareVM.name
      "vCenter" = $($vmwareVM.physicalPath[-1].name)
      "SLA" = $vmwareVM.effectiveSlaDomain.name
      "Disk" = $vmwareDisk.fileName
      "Size" = $vmwareDisk.size
      "SizeGB" = $($vmwareDisk.size / 1000 / 1000 / 1000)
      "SizeGiB" = $($vmwareDisk.size / 1024 / 1024 / 1024)
      "vmID" = $vmwareVM.id
      "vmDiskFid" = $vmwareDisk.fid
      "excludeFromSnapshots" = $vmwareDisk.excludeFromSnapshots
      "setExclude" = ""
    }
    $vmwareCSV += $vmwareDetails
  }
}

$ahvCsv | Export-Csv -NoTypeInformation -Path $ahvCsvOutput
$vmwareCsv | Export-Csv -NoTypeInformation -Path $vmwareCsvOutput
Write-Host "Exported AHV CSV: $ahvCsvOutput" -foregroundcolor green
Write-Host "Exported VMware CSV: $vmwareCsvOutput" -foregroundcolor green

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
