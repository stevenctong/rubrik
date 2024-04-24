# https://www.rubrik.com/api
<#
.SYNOPSIS
This script can generate a list of VMs in Rubrik and then try to register RBS
on each VM.

.DESCRIPTION
This script can generate a list of VMs in Rubrik and then try to register RBS
on each VM.

You can set the $clusters variable to filter by a list of clusters.

The results of each attempt will be output to a CSV file.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/15/24

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-Set-VM-RBS_Reg.ps1
Runs the script to generate get a list of all VMs and register RBS on those VMs.
#>

### Variables section - please fill out as needed


param (
  [CmdletBinding()]

  # List of clusters to register RBS on
  [Parameter(Mandatory=$false)]
  [array]$clusters = @('vault-r-melbourne', 'vault-r-madison')
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV file info
$csvOutput = "./rubrik_vm_reg_rbs-$($date.ToString("yyyy-MM-dd_HHmm")).csv"


# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false


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
          agentStatus {
            agentStatus
            disconnectReason
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

# Register RBS for a VM
Function Set-RegsterVmRBS {
  param (
    [CmdletBinding()]
    # VM ID
    [Parameter(Mandatory=$true)]
    [string]$vmID = ''
  )
  $variables = @{
    "input" = @{
      "id" = $vmID
    }
  }
  $query = "mutation RegisterRubrikBackupServiceMutation(`$input: VsphereVmRegisterAgentInput!) {
    vsphereVmRegisterAgent(input: `$input) {
      success
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers -verbose -TimeoutSec 30
  $response
  return $response
} ### Function Set-RegsterVmRBS


###### FUNCTIONS - END ######


Write-Host "Getting a list of all VMs"
$vmList = @()
$afterCursor = ''
do {
  $vmInventory = Get-VMList -afterCursor $afterCursor
  $vmList += $vmInventory.edges.node
  $afterCursor = $vmInventory.pageInfo.endCursor
} while ($vmInventory.pageInfo.hasNextPage)

# Filter list by VMs that are unregistered
$unRegVMList = $vmList | Where { $_.agentStatus.agentStatus -eq 'UNREGISTERED' }

# Filter list by VMs that have a primary cluster specified in the variables
$newVMList = $unRegVMList | Where { $_.primaryClusterLocation.name -in $clusters }

# Hold results for each register RBS attempt to export out as CSV
$resultArray = @()

$newVMListCount = $newVMList.count
$count = 1

# Loop through each VM and attemp to register RBS on the VM
foreach ($vm in $newVMList) {
  Write-Host "[$count / $newVMListCount] Attempting to register RBS on: $($vm.name)"
  $count++
  $result = Set-RegsterVmRBS -vmID $vm.id
  $info = [PSCustomObject] @{
    "VM" = $vm.name
    "Cluster" = $vm.primaryClusterLocation.Name
    "ID" = $vm.id
    "Data" = $result.data[0]
    "Errors" = $result.errors.message[0]
  }
  $resultArray += $info
}

$resultArray | Export-CSV -Path $csvOutput -NoTypeInformation
Write-Host "CSV output to: $csvOutput" -foregroundcolor green

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
