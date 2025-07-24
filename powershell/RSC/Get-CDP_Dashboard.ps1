# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get the CDP Dashboard and export it to a CSV file.

.DESCRIPTION
This script will get the CDP Dashboard and export it to a CSV file.
Options for emailing out the script if SMTP info is filled out.

Create a custom role with View Only permissions to VMware objects.
Create a Service Account and assign it that custom role.
Download the Service Account json and put it's location in: $serviceaccountpath.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/22/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a custom role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

.EXAMPLE
./Get-CDP-Dashboard.ps1
Runs the script with default arguments and exports it to a CSV file.

#>

###### VARIABLES - BEGIN ######

# param (
#   [CmdletBinding()]
#   #
#   [Parameter(Mandatory=$false)]
#   [string]$cluster = ''
# )

# File location of the RSC service account json
$serviceAccountPath = "./rsc-gaia.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV file info
$csvOutput = "./rubrik-cdp-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik - CDP Dashboard - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

###### VARIABLES - END ######

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
} catch {
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

# Get the CDP Dashboard details
Function Get-CDP-Dashboard {
  $variables = @{
    "sortBy" = "VM_NAME"
    "sortOrder" = "ASC"
    "filter" = @(
      @{
        "vmName" = ""
        "sourceClusterUuids" = @()
        "slaDomainIds" = @()
        "localStatus" = @()
        "replicationStatus" = @()
        "cdpIoFilterStatus" = @()
        "filterField" = "VM_NAME"
      }
    )
    "first" = 500
  }
  $query = 'query AllCdpVmsInfoQuery($first: Int, $after: String, $filter: [CdpPerfDashboardFilterParam!]!, $sortBy: CdpPerfDashboardSortType, $sortOrder: SortOrder) {
  allCdpVmsInfos(first: $first, after: $after, allCdpVmInfoFilter: $filter, allCdpVmInfoSort: {type: $sortBy, sortOrder: $sortOrder}) {
    edges {
      cursor
      node {
        vmId
        vmName
        vmLocation
        sourceCluster
        replicationTarget
        slaDomainName
        cdpLocalStatus
        cdpReplicationStatus
        ioFilterStatus
        latestSnapshotTime
        __typename
      }
      __typename
    }
    pageInfo {
      startCursor
      endCursor
      hasPreviousPage
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
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.allCdpVmsInfos.edges.node
} ### Get-CDP-Dashboard

# Get the CDP recovery points per VM
Function Get-CDP-VM-Info {
  param (
    [CmdletBinding()]
    # VM ID
    [Parameter(Mandatory=$true)]
    [string]$vmID = ''
  )
  $variables = @{
    "ids" = @(
      $vmID
    )
  }
  $query = 'query VsphereVmwareCdpLiveInfoQuery($ids: [String!]!) {
  vsphereVmwareCdpLiveInfo(ids: $ids) {
    responses {
      currentTime
      localRecoveryPoint
      remoteRecoveryPoint
      vmId
      __typename
    }
    __typename
  }
}'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.vsphereVmwareCdpLiveInfo.responses[0]
} ### Get-CDP-VM-Info


###### FUNCTIONS - END ######

Write-Host "Getting CDP dashboard info"
$cdpVMs = Get-CDP-Dashboard

foreach ($vm in $cdpVMs) {
  $vmInfo = Get-CDP-VM-Info -vmID $vm.vmId
  $vm | Add-Member -MemberType NoteProperty -name 'localRecoveryPoint' -value $($vmInfo.localRecoveryPoint) -Force
  $vm | Add-Member -MemberType NoteProperty -name 'remoteRecoveryPoint' -value $($vmInfo.remoteRecoveryPoint) -Force
  $vm | Add-Member -MemberType NoteProperty -name 'currentTime' -value $($vmInfo.currentTime) -Force
}

Write-Host "Exporting to CSV: $csvOutput"
$cdpVMs | Export-CSV -Path $csvOutput -NoTypeInformation

# Send an email with CSV attachment
if ($sendEmail) {
  $htmlReport = ""
  Write-Host "Sending email to: $emailTo with subject: $emailSubject"
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}
