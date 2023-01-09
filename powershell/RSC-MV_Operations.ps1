<#
.SYNOPSIS
This script will open or close a Managed Volume (MV) according to the command line arguments.

.DESCRIPTION
This script will open or close a Managed Volume (MV) according to the command line arguments.
Opening a MV will make the share read-writable.
Closing a MV will make the share read-only and allow Rubrik to take a snapshot.
A MV should always be closed once a backup has been written to it.

-mvName - Managed Volume name, provide either MV Name + Cluster OR MV ID
-cluster - Rubrik cluster, provide either MV Name + Cluster OR MV ID
-mvID - MV ID, provide either MV Name + Cluster OR MV ID
-op - Either 'open' or 'close'

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/7/23

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./RSC-MV-Operations.ps1 -mvName <mvName> -cluster <cluster> -op 'open'
Open the Managed Volume with the specific name + cluster to writeable.

./RSC-MV-Operations.ps1 -mvName <mvName> -cluster <cluster> -op 'close'
Close the Managed Volume with the specific name + cluster to read-only.

./RSC-MV-Operations.ps1 -mvID <mvID> -op 'open'
Use a MV ID to open it to a writable state.
#>


param (
  [CmdletBinding()]

  # MV name, provide with Rubrik cluster instead of MV ID
  [Parameter(Mandatory=$false)]
  [string]$mvName,

  # Rubrik cluster, provide with MV name instead of MV ID
  [Parameter(Mandatory=$false)]
  [string]$cluster,

  # MV ID, provide instead of MV Name + Rubrik cluster
  [Parameter(Mandatory=$false)]
  [string]$mvID,

  # Managed Volume action - open or close
  [Parameter(Mandatory=$true)]
  [string]$op
)

$date = Get-Date

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email at the end of this script
$sendEmail = $false

###### RUBRIK AUTHENTICATION - BEGIN ######

$serviceAccountPath = "./rsc-service-account.json"

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
  'Accept'       = 'application/json';
}

Write-Debug -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

Write-Verbose -Message "Creating the Rubrik Security Cloud connection global variable."

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

Write-Information -Message "Info: Successfully connected to $rubrikURL."

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Find a MV with an exact match for $mvName
Function Find-ManagedVolume {
  param (
    [CmdletBinding()]
    # Managed Volume Name
    [Parameter(Mandatory=$true)]
    [string]$mvName,
    # Rubrik Cluster ID
    [Parameter(Mandatory=$true)]
    [string]$clusterID
  )
  $variables = @{
    "first" = 200
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "filter" = @(
      @{
        "field" = "NAME_EXACT_MATCH";
        "texts" = @(
          "$mvName"
        )
      },
      @{
        "field" = "CLUSTER_ID";
        "texts" = @(
          "$clusterID"
        )
      },
      @{
        "field" = "IS_RELIC";
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_REPLICATED";
        "texts" = @(
          "false"
        )
      }
    )
  }
  $query = "query (`$first: Int!, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]!) {
    managedVolumes(filter: `$filter, first: `$first, after: `$after, sortBy: `$sortBy, sortOrder: `$sortOrder) {
      count
      edges {
        cursor
        node {
          id
          name
          cluster {
            id
            name
          }
          effectiveSlaDomain {
            id
            name
          }
          protocol
          mountState
          state
          isRelic
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
  $mvResult = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.ManagedVolumes.edges.node
  return $mvResult
}  ### Function Find-ManagedVolume

# Find a Rubrik cluster with an exact match for $cluster
Function Find-Cluster {
  param (
    [CmdletBinding()]
    # Rubrik cluster name
    [Parameter(Mandatory=$true)]
    [string]$cluster
  )
  $variables = @{
    "filter" = @{
      "name" = @(
        "$cluster"
      )
    }
  }
  $query = "query (`$filter: ClusterFilterInput) {
    clusterConnection(filter: `$filter) {
      edges {
        node {
          id
          name
          type
          version
          __typename
        }
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $clusterResult = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.clusterConnection.edges.node
  # Loop through results to filter for an exact match
  $clusterMatch = $null
  foreach ($i in $clusterResult)
  {
    if ($i.name -eq $cluster) {
      $clusterMatch = $i
    }
  }
  return $clusterMatch
}  ### Function Find-Cluster

# Open a MV to a writable state
Function Open-MV {
  param (
    [CmdletBinding()]
    # Managed Volume ID
    [Parameter(Mandatory=$true)]
    [string]$mvID
  )
  $variables = @{
    "input" = @{
      "id" = $mvID
      "config" = @{
        "isAsync" = $true
      }
    }
  }
  $query = "mutation (`$input: BeginManagedVolumeSnapshotInput!) {
    beginManagedVolumeSnapshot(input: `$input) {
      asyncRequestStatus {
        id
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response
}  ### Function Open-MV

# Close a MV to a read-only state
Function Close-MV {
  param (
    [CmdletBinding()]
    # Managed Volume ID
    [Parameter(Mandatory=$true)]
    [string]$mvID
  )
  $variables = @{
    "input" = @{
      "id" = $mvID
      "params" = @{
        "isAsync" = $true
      }
    }
  }
  $query = "mutation (`$input: EndManagedVolumeSnapshotInput!) {
    endManagedVolumeSnapshot(input: `$input) {
      asyncRequestStatus {
        id
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response
}  ### Function Close-MV

###### FUNCTIONS - END ######

# If a MV ID is not provided then find the MV ID using the MV Name + Rubrik Cluster
if ($mvID -eq '' -Or $mvID -eq $null)
{
  if ($mvName -eq '' -Or $mvName -eq $null) {
    Write-Error "No MV name provided. Exiting..."
    exit
  }
  if ($cluster -eq '' -Or $cluster -eq $null) {
    Write-Error "No Rubrik cluster provided. Exiting..."
    exit
  }
  $clusterResult = Find-Cluster -cluster $cluster
  if ($clusterResult.count -eq 0) {
    Write-Error "No cluster found by name: $cluster. Exiting..."
    exit
  }
  $clusterID = $clusterResult.id
  $mvResult = Find-ManagedVolume -mvName $mvName -clusterID $clusterID
  if ($mvResult.count -eq 0) {
    Write-Error "No MV found by name: $mvName on cluster: $cluster. Exiting..."
    exit
  }
  $mvID = $mvResult.id
}

if ($op -eq 'open')
{
  Write-Host "Opening MV: $mvName ($mvID) on cluster: $cluster"
  $response = Open-MV -mvID $mvID
  if ($response.errors -eq $null) {
    Write-Host "Opened MV: $mvName ($mvID) on cluster: $cluster for writing." -foregroundcolor green
  } else {
    Write-Error "Error opening MV: $mvName ($mvID) on cluster: $cluster"
    Write-Error "$($response.errors.message)"
  }
} elseif ($op -eq 'close') {
  Write-Host "Closing MV: $mvName ($mvID) on cluster: $cluster"
  $response = Close-MV -mvID $mvID
  if ($response.errors -eq $null) {
    Write-Host "Closed MV: $mvName ($mvID) on cluster: $cluster to read-only." -foregroundcolor green
  } else {
    Write-Error "Error closing MV: $mvName ($mvID) on cluster: $cluster"
    Write-Error "$($response.errors.message)"
  }
}

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}
