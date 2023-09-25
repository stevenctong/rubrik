# https://www.rubrik.com/api
<#
.SYNOPSIS
This script can generate a list of VMs in Rubrik, export it to a RSC with
the consistency level of each VM, and then use that list to set a new
consistency level.

.DESCRIPTION
This script can generate a list of VMs in Rubrik, export it to a RSC with
the consistency level of each VM, and then use that list to set a new
consistency level.

APP CONSISTENCY = UKNOWN CONSISTENCY in the CSV list

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 9/22/23

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-Set-App_Consistency.ps1
Runs the script to generate to export all VMs as a CSV.

./Get-Set-App_Consistency.ps1 -csvInput 'rubrik_vm_list.csv' -consistencyLevel 'CRASH'
Import list of VMs from CSV and set all VMs to crash consistency

./Get-Set-App_Consistency.ps1 -csvInput 'rubrik_vm_list.csv' -consistencyLevel 'APP'
Import list of VMs from CSV and set all VMs to app consistency (aka UNKNOWN consistency)
#>

### Variables section - please fill out as needed


param (
  [CmdletBinding()]

  # CSV of list of VMs to set consistency level for
  [Parameter(Mandatory=$false)]
  [string]$csvInput = '',

  # If importing a CSV, the consistency level to set, either "APP" or "CRASH"
  [Parameter(Mandatory=$false)]
  [string]$consistencyLevel = ''
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

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
$csvOutput = "./rubrik_vm_list_consistency-$($date.ToString("yyyy-MM-dd_HHmm")).csv"


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
          snapshotConsistencyMandate
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
  $vmList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.vSphereVmNewConnection
  return $vmList
}  ### Function VMList

# Set app consistency for a VM
Function Set-AppConsistency {
  param (
    [CmdletBinding()]
    # VM ID
    [Parameter(Mandatory=$true)]
    [string]$vmID = '',
    # Consistency level to set, either APP or CRASH
    [Parameter(Mandatory=$true)]
    [string]$consistencyLevel = ''
  )
  if ($consistencyLevel -eq 'CRASH') {
    $setLevel = 'VIRTUAL_MACHINE_UPDATE_SNAPSHOT_CONSISTENCY_MANDATE_CRASH_CONSISTENT'
  } else {
    $setLevel = 'VIRTUAL_MACHINE_UPDATE_SNAPSHOT_CONSISTENCY_MANDATE_UNKNOWN'
  }
  $variables = @{
    "input" = @{
      "id" = $vmID
      "vmUpdateProperties" = @{
        "virtualMachineUpdate" = @{
          "snapshotConsistencyMandate" = $setLevel
        }
      }
    }
  }
  $query = "mutation (`$input: UpdateVsphereVmInput!) {
    updateVsphereVm(input: `$input) {
      success
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response.data.downloadReportCsvAsync
} ### Function Set-AppConsistency


###### FUNCTIONS - END ######

if ($csvInput -eq '')
{
  Write-Host "No input CSV given, generating a list of VMs"
  $vmList = @()
  $afterCursor = ''
  do {
    $vmInventory = Get-VMList -afterCursor $afterCursor
    $vmList += $vmInventory.edges.node
    $afterCursor = $vmInventory.pageInfo.endCursor
  } while ($vmInventory.pageInfo.hasNextPage)
  # Export the list to a CSV file
  $vmList | Export-Csv -NoTypeInformation -Path $csvOutput
  Write-Host "`nResults output to: $csvOutput"
} else {
  if ($consistencyLevel -ne 'APP' -and $consistencyLevel -ne 'CRASH') {
    Write-Host "Parameter `'-ConsistencyLevel`' must be either APP or CRASH" -foregroundcolor yellow
    Write-Host "Exiting..." -foregroundcolor yellow
    exit
  }
  Write-Host "Importing CSV: $csvInput"
  $vmList = Import-Csv $csvInput
  $vmCount = $vmList.count
  Write-Host "$vmCount VMs found"
  Write-Host "Setting consistency level of VMs to: $consistencyLevel"
  $count = 1
  foreach ($vm in $vmList) {
    Write-Host "[$count / $vmCount] Configuring VM: $($vmList.name)"
    Set-AppConsistency -vmID $vm.id -consistencyLevel $consistencyLevel
  }
}





# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
