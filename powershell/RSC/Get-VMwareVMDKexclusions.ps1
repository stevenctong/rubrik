# https://www.rubrik.com/api
<#
.SYNOPSIS
Gets all VMware VMs and checks each for VMDK exclusions.

.DESCRIPTION
Gets the full inventory of VMware VMs from RSC, checks each VM for VMDK
exclusions, and outputs a CSV with each VM, exclusion status, and individual
disk details (name, size, excluded) in separate columns.

The script uses a single paginated GraphQL query that retrieves all VMs
with their virtual disk details including the excludeFromSnapshots field.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/10/26

The script requires communication to RSC via outbound HTTPS (TCP 443).

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

Update this variable to point to your RSC Service Account JSON:
- $serviceAccountPath

.PARAMETER serviceAccountPath
Path to the RSC service account JSON file. Default: ./rsc-gaia.json

.EXAMPLE
./Get-VMwareVMDKexclusions.ps1
Gets all VMware VMs and their VMDK exclusion status, outputs to CSV.

.EXAMPLE
./Get-VMwareVMDKexclusions.ps1 -serviceAccountPath ./my-service-account.json
Uses a custom service account JSON file.

#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = "./rsc_svc.json"
)

$date = Get-Date
$utcDate = $date.ToUniversalTime()

$csvOutput = "./rubrik_vmware_vmdk_exclusions-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### VARIABLES - END ###

if ([string]::IsNullOrEmpty($serviceAccountPath)) {
  Write-Host ""
  Write-Host "Usage: ./Get-VMwareVMDKexclusions.ps1 [-serviceAccountPath <path>]" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Gets all VMware VMs and checks each for VMDK exclusions."
  Write-Host "Outputs a CSV with VM details, exclusion status, and disk info."
  Write-Host ""
  Write-Host "Parameters:"
  Write-Host "  -serviceAccountPath  Path to RSC service account JSON (default: ./rsc-gaia.json)"
  Write-Host ""
  exit
}

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

# Get VMware VM list with virtual disk details including exclusion status
Function Get-VMList {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "first" = 1000
    "filter" = @(
      @{
        "field" = "IS_GHOST"
        "texts" = @("false")
      }
      @{
        "field" = "IS_RELIC"
        "texts" = @("false")
      }
      @{
        "field" = "IS_REPLICATED"
        "texts" = @("false")
      }
      @{
        "field" = "IS_ACTIVE"
        "texts" = @("true")
      }
      @{
        "field" = "IS_ACTIVE_AMONG_DUPLICATED_OBJECTS"
        "texts" = @("true")
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query GetVMwareVMsWithDisksQuery(`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereVmNewConnection(filter: `$filter, first: `$first, after: `$after, sortBy: `$sortBy, sortOrder: `$sortOrder) {
      edges {
        cursor
        node {
          id
          name
          objectType
          slaAssignment
          effectiveSlaDomain {
            ... on GlobalSlaReply {
              id
              name
            }
            ... on ClusterSlaDomain {
              id
              fid
              name
            }
          }
          cluster {
            id
            name
          }
          vsphereVirtualDisks {
            edges {
              node {
                fid
                fileName
                size
                excludeFromSnapshots
              }
            }
          }
        }
      }
      pageInfo {
        endCursor
        hasNextPage
      }
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.vSphereVmNewConnection
}

###### FUNCTIONS - END ######

# Get all VMware VMs with disk details
Write-Host "Getting all VMware VMs with disk details..."
$vmList = @()
$afterCursor = ''
do {
  $vmConnection = Get-VMList -afterCursor $afterCursor
  $vmList += $vmConnection.edges.node
  $afterCursor = $vmConnection.pageInfo.endCursor
} while ($vmConnection.pageInfo.hasNextPage)

Write-Host "Total VMware VMs found: $($vmList.count)"

# Determine maximum number of disks across all VMs for column generation
$maxDisks = 0
foreach ($vm in $vmList) {
  $diskCount = $vm.vsphereVirtualDisks.edges.count
  if ($diskCount -gt $maxDisks) {
    $maxDisks = $diskCount
  }
}
Write-Host "Maximum disks on a single VM: $maxDisks"

# Build output list with dynamic disk columns
$csvList = @()
foreach ($vm in $vmList) {
  $disks = $vm.vsphereVirtualDisks.edges.node
  $diskCount = if ($null -eq $disks) { 0 } elseif ($disks -is [array]) { $disks.count } else { 1 }

  # Normalize to array
  if ($diskCount -eq 1 -and $disks -isnot [array]) {
    $disks = @($disks)
  } elseif ($diskCount -eq 0) {
    $disks = @()
  }

  $hasExclusions = $false
  foreach ($disk in $disks) {
    if ($disk.excludeFromSnapshots -eq $true) {
      $hasExclusions = $true
      break
    }
  }

  $row = [ordered]@{
    "VM Name" = $vm.name
    "VM ID" = $vm.id
    "Cluster" = $vm.cluster.name
    "SLA Domain" = $vm.effectiveSlaDomain.name
    "SLA Assignment" = $vm.slaAssignment
    "Total Disks" = $diskCount
    "Has Exclusions" = $hasExclusions
  }

  for ($i = 0; $i -lt $maxDisks; $i++) {
    $diskNum = $i + 1
    if ($i -lt $diskCount) {
      $row["Disk $diskNum Name"] = $disks[$i].fileName
      $row["Disk $diskNum Size (GB)"] = [math]::Round($disks[$i].size / 1073741824, 2)
      $row["Disk $diskNum Excluded"] = $disks[$i].excludeFromSnapshots
    } else {
      $row["Disk $diskNum Name"] = ''
      $row["Disk $diskNum Size (GB)"] = ''
      $row["Disk $diskNum Excluded"] = ''
    }
  }

  $csvList += New-Object PSObject -Property $row
}

# Count VMs with exclusions
$exclusionCount = ($csvList | Where-Object { $_.'Has Exclusions' -eq $true }).count
Write-Host "VMs with VMDK exclusions: $exclusionCount out of $($vmList.count)"

$csvList | Export-Csv -Path $csvOutput -NoTypeInformation
Write-Host "CSV output to: $csvOutput" -ForegroundColor Green
