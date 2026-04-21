# https://www.rubrik.com/api
<#
.SYNOPSIS
Opens or closes a Managed Volume (MV) via the RSC GraphQL API or CDM REST API.

.DESCRIPTION
Opens or closes a Managed Volume (MV) via the RSC GraphQL API or CDM REST API.
Opening a MV makes the share read-writable so backups can be written to it.
Closing a MV makes the share read-only and triggers Rubrik to take a snapshot.

A MV should always be closed once a backup has been written to it.

There are two modes of operation:

RSC mode (default):
  Provide either -mvID alone, or -mvName + -clusterName to look up the MV ID.

CDM mode (when -clusterIP is provided):
  Uses the CDM REST API directly against the cluster.
  Provide either -mvID or -mvName to look up the MV ID.

.PARAMETER RscServiceAccountJson
File path to the RSC Service Account JSON file containing client_id
and client_secret. For RSC mode, the JSON must also contain access_token_uri.

.PARAMETER clusterIP
IP address or hostname of the Rubrik CDM cluster. When provided, the script
uses the CDM REST API instead of RSC GraphQL.

.PARAMETER mvName
Managed Volume name. In RSC mode, use with -clusterName. In CDM mode, used to
look up the MV ID on the target cluster.

.PARAMETER clusterName
Rubrik cluster name. Only used in RSC mode with -mvName to look up the MV ID.

.PARAMETER mvID
Managed Volume ID. Use instead of -mvName (and -clusterName in RSC mode).
The ID can be found in the URL of the object.
CDM format: "ManagedVolume:::6630d59b-6804-49c6-96aa-9c76082e918f"
RSC format: "7407757b-4906-58f8-b2bb-5a48e6c4f874"

.PARAMETER op
Operation to perform: 'open' or 'close'.

.PARAMETER logDir
Directory to write log files to. When provided, all script output is logged
to a timestamped file: <logDir>/rubrik_mv_openclose-<timestamp>.log
Useful for troubleshooting — the log captures all console output including errors.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/7/23
Updated: 4/20/26

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a role
** The role only needs the "Take On Demand Snapshot" privilege for the
   managed volumes that it will be opening / closing.
** Download the service account JSON
** Define the service account JSON path: -RscServiceAccountJson

Requires PowerShell 7+.

.EXAMPLE
./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -mvName 'my-mv' -clusterName 'my-cluster' -op 'open'
RSC mode: Open the Managed Volume by name + cluster to a writable state.

.EXAMPLE
./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -mvID 'ca62b0dc-4175-5eca-828c-6393859f6319' -op 'close'
RSC mode: Close a Managed Volume by ID to read-only and take a snapshot.

.EXAMPLE
./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -clusterIP '10.8.49.104' -mvName 'my-mv' -op 'open'
CDM mode: Open the Managed Volume by name using the CDM REST API.

.EXAMPLE
./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -clusterIP '10.8.49.104' -mvID 'ManagedVolume:::abc-123' -op 'close'
CDM mode: Close a Managed Volume by ID using the CDM REST API.

.EXAMPLE
./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -mvName 'my-mv' -clusterName 'my-cluster' -op 'open' -logDir '/var/log/rubrik'
Open the Managed Volume and log all output to /var/log/rubrik/.
#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson,
  # IP address or hostname of the Rubrik CDM cluster (enables CDM REST API mode)
  [Parameter(Mandatory=$false)]
  [string]$clusterIP,
  # Managed Volume name
  [Parameter(Mandatory=$false)]
  [string]$mvName,
  # Rubrik cluster name, use with -mvName in RSC mode
  [Parameter(Mandatory=$false)]
  [string]$clusterName,
  # Managed Volume ID
  [Parameter(Mandatory=$false)]
  [string]$mvID,
  # Operation: 'open' or 'close'
  [Parameter(Mandatory=$false)]
  [string]$op,
  # Directory to write log files to
  [Parameter(Mandatory=$false)]
  [string]$logDir
)

$date = Get-Date
$pstZone = [TimeZoneInfo]::FindSystemTimeZoneById('America/Los_Angeles')
$startTimePST = [TimeZoneInfo]::ConvertTimeFromUtc($date.ToUniversalTime(), $pstZone)

# Determine mode based on whether clusterIP is provided
$cdmMode = -not [string]::IsNullOrEmpty($clusterIP)

# Start logging if logDir is provided
$logging = $false
if (-not [string]::IsNullOrEmpty($logDir)) {
  if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }
  $logFile = Join-Path $logDir "rubrik_mv_openclose-$($date.ToString('yyyy-MM-dd_HHmmss')).log"
  Start-Transcript -Path $logFile -NoClobber
  $logging = $true
  Write-Host "Logging to: $logFile"
}

### VARIABLES - END ###

# Show usage if no meaningful parameters provided
if ([string]::IsNullOrEmpty($op)) {
  Write-Host ""
  Write-Host "Usage: Invoke-MV-Open-Close.ps1 -RscServiceAccountJson <path> -op <open|close> [options]" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  -RscServiceAccountJson  Path to RSC service account JSON"
  Write-Host "  -op                     'open' to make MV writable, 'close' to make MV read-only and snapshot"
  Write-Host "  -mvID                   Managed Volume ID (use instead of -mvName)"
  Write-Host "  -mvName                 Managed Volume name"
  Write-Host "  -clusterName            Rubrik cluster name (RSC mode only, use with -mvName)"
  Write-Host "  -clusterIP              CDM cluster IP/hostname (enables CDM REST API mode)"
  Write-Host "  -logDir                 Directory to write log files for troubleshooting"
  Write-Host ""
  Write-Host "RSC mode (default):"
  Write-Host "  ./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -mvName 'my-mv' -clusterName 'my-cluster' -op 'open'"
  Write-Host "  ./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -mvID 'ca62b0dc-...' -op 'close'"
  Write-Host ""
  Write-Host "CDM mode (with -clusterIP):"
  Write-Host "  ./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -clusterIP '10.8.49.104' -mvName 'my-mv' -op 'open'"
  Write-Host "  ./Invoke-MV-Open-Close.ps1 -RscServiceAccountJson './rsc-sa.json' -clusterIP '10.8.49.104' -mvID 'ManagedVolume:::abc' -op 'close'"
  Write-Host ""
  exit
}

if ($op -ne 'open' -and $op -ne 'close') {
  Write-Error "Invalid -op value: '$op'. Must be 'open' or 'close'."
  if ($logging) { Stop-Transcript }
  exit 1
}

if ([string]::IsNullOrEmpty($RscServiceAccountJson)) {
  Write-Error "No -RscServiceAccountJson provided. Specify the path to the RSC service account JSON file."
  if ($logging) { Stop-Transcript }
  exit 1
}

# Require PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Error "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
  if ($logging) { Stop-Transcript }
  exit 1
}

Write-Host "Script start time (PST): $($startTimePST.ToString('yyyy-MM-dd HH:mm:ss'))"

# Build display label for messages (avoids blank name when using -mvID directly)
$mvLabel = if (-not [string]::IsNullOrEmpty($mvName)) { "$mvName ($mvID)" } else { $mvID }

if ($cdmMode) {
  ###### CDM REST API AUTHENTICATION - BEGIN ######

  Write-Host "CDM mode: targeting cluster $clusterIP via REST API"
  Write-Host "Reading Service Account file: $RscServiceAccountJson"
  try {
    $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
  } catch {
    throw "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
  }

  # Validate required fields
  $missingFields = @()
  if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
  if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }

  if ($missingFields.Count -gt 0) {
    throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
  }

  # Exchange credentials for bearer token via CDM session API
  try {
    $response = Invoke-RestMethod -Method POST -ContentType 'application/json' -SkipCertificateCheck `
      -Uri "https://$clusterIP/api/v1/service_account/session" `
      -Body (@{ serviceAccountId = $serviceAccountFile.client_id; secret = $serviceAccountFile.client_secret } | ConvertTo-Json) `
      -ErrorAction Stop
  } catch {
    throw "CDM authentication failed: $($_.Exception.Message)"
  }

  if ([string]::IsNullOrEmpty($response.token)) {
    throw "CDM returned a response but no bearer token was included."
  }

  # Set connection variables
  $rubrikURL = "https://$clusterIP"
  $sessionId = $response.sessionId

  $global:rubrikConnection = @{
    accessToken = $response.token
    bearer      = "Bearer $($response.token)"
    rubrikURL   = $rubrikURL
    sessionId   = $sessionId
  }

  $endpoint = "$rubrikURL/api/v1"

  $headers = @{
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
    'Authorization' = "Bearer $($response.token)"
  }

  Write-Host "Connected to CDM cluster: $clusterIP" -ForegroundColor Green

  ###### CDM REST API AUTHENTICATION - END ######
} else {
  ###### RSC GRAPHQL AUTHENTICATION - BEGIN ######

  Write-Host "RSC mode: using RSC GraphQL API"
  Write-Host "Reading Service Account file: $RscServiceAccountJson"
  try {
    $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
  } catch {
    throw "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
  }

  # Validate required fields
  $missingFields = @()
  if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
  if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
  if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

  if ($missingFields.Count -gt 0) {
    throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
  }

  # Exchange credentials for bearer token
  $payload = @{
    grant_type    = "client_credentials"
    client_id     = $serviceAccountFile.client_id
    client_secret = $serviceAccountFile.client_secret
  }

  try {
    $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri `
      -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
  } catch {
    throw "RSC authentication failed: $($_.Exception.Message)"
  }

  if ($null -eq $response.access_token) {
    throw "RSC returned a response but no access token was included."
  }

  # Set connection variables
  $rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

  $global:rubrikConnection = @{
    accessToken = $response.access_token
    bearer      = "Bearer $($response.access_token)"
    rubrikURL   = $rubrikURL
  }

  $endpoint = $rubrikURL + "/api/graphql"

  $headers = @{
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
    'Authorization' = "Bearer $($response.access_token)"
  }

  Write-Host "Connected to RSC: $rubrikURL" -ForegroundColor Green

  ###### RSC GRAPHQL AUTHENTICATION - END ######
}

###### FUNCTIONS - BEGIN ######

# Delete CDM session - call before exiting when in CDM mode
Function Remove-RubrikSession {
  $conn = $global:rubrikConnection
  if ($null -eq $conn -or [string]::IsNullOrEmpty($conn.sessionId)) {
    return
  }
  $deleteHeaders = @{
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
    'Authorization' = $conn.bearer
  }
  try {
    Invoke-RestMethod -Method DELETE -SkipCertificateCheck -Headers $deleteHeaders `
      -Uri "$($conn.rubrikURL)/api/v1/session/$([Uri]::EscapeDataString($conn.sessionId))" | Out-Null
    Write-Host "CDM session deleted." -ForegroundColor DarkGray
  } catch {
    Write-Warning "Failed to delete CDM session: $($_.Exception.Message)"
  }
}

### RSC Functions ###

# Find a Rubrik cluster by exact name match (RSC mode)
Function Find-Cluster {
  param (
    [CmdletBinding()]
    # Rubrik cluster name
    [Parameter(Mandatory=$true)]
    [string]$clusterName
  )
  $variables = @{
    "filter" = @{
      "name" = @(
        "$clusterName"
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
  # Filter for an exact name match
  $clusterMatch = $null
  foreach ($i in $clusterResult) {
    if ($i.name -eq $clusterName) {
      $clusterMatch = $i
    }
  }
  return $clusterMatch
}  ### Function Find-Cluster

# Find a Managed Volume by exact name match on a specific cluster (RSC mode)
Function Find-ManagedVolume {
  param (
    [CmdletBinding()]
    # Managed Volume name
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
        "field" = "NAME_EXACT_MATCH"
        "texts" = @( "$mvName" )
      },
      @{
        "field" = "CLUSTER_ID"
        "texts" = @( "$clusterID" )
      },
      @{
        "field" = "IS_RELIC"
        "texts" = @( "false" )
      },
      @{
        "field" = "IS_REPLICATED"
        "texts" = @( "false" )
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
  $mvResult = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.managedVolumes.edges.node
  return $mvResult
}  ### Function Find-ManagedVolume

# Open a Managed Volume to a writable state (RSC mode)
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

# Close a Managed Volume to a read-only state and take a snapshot (RSC mode)
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

### CDM Functions ###

# Find a Managed Volume ID by name (CDM mode)
Function Find-ManagedVolumeCDM {
  param (
    [CmdletBinding()]
    # Managed Volume name
    [Parameter(Mandatory=$true)]
    [string]$mvName
  )
  $getURL = "$($global:rubrikConnection.rubrikURL)/api/internal/managed_volume?name=$mvName"
  $mvResult = $(Invoke-RestMethod -Uri $getURL -Headers $headers -Method GET -SkipCertificateCheck).data
  if ($null -eq $mvResult -or $mvResult.Count -eq 0) {
    return $null
  }
  return $mvResult[0].id
}  ### Function Find-ManagedVolumeCDM

# Open a Managed Volume to a writable state (CDM mode)
Function Open-MV-CDM {
  param (
    [CmdletBinding()]
    # Managed Volume ID
    [Parameter(Mandatory=$true)]
    [string]$mvID
  )
  $mvURL = "$endpoint/managed_volume/$mvID/begin_snapshot"
  $response = Invoke-RestMethod -Uri $mvURL -Headers $headers -Method POST -ContentType 'application/json' -SkipCertificateCheck
  return $response
}  ### Function Open-MV-CDM

# Close a Managed Volume to a read-only state (CDM mode)
Function Close-MV-CDM {
  param (
    [CmdletBinding()]
    # Managed Volume ID
    [Parameter(Mandatory=$true)]
    [string]$mvID
  )
  $mvURL = "$endpoint/managed_volume/$mvID/end_snapshot"
  $response = Invoke-RestMethod -Uri $mvURL -Headers $headers -Method POST -ContentType 'application/json' -SkipCertificateCheck
  return $response
}  ### Function Close-MV-CDM

###### FUNCTIONS - END ######

if ($cdmMode) {
  ### CDM MODE ###

  # Resolve MV ID if not provided directly
  if ([string]::IsNullOrEmpty($mvID)) {
    if ([string]::IsNullOrEmpty($mvName)) {
      Write-Error "No -mvID or -mvName provided."
      Remove-RubrikSession
      if ($logging) { Stop-Transcript }
      exit 1
    }
    Write-Host "Looking up Managed Volume: $mvName"
    $mvID = Find-ManagedVolumeCDM -mvName $mvName
    if ([string]::IsNullOrEmpty($mvID)) {
      Write-Error "No Managed Volume found with name: $mvName on cluster: $clusterIP"
      Remove-RubrikSession
      if ($logging) { Stop-Transcript }
      exit 1
    }
    Write-Host "Found Managed Volume: $mvName ($mvID)"
  }

  # Update display label now that mvID is resolved
  $mvLabel = if (-not [string]::IsNullOrEmpty($mvName)) { "$mvName ($mvID)" } else { $mvID }

  # Execute the open or close operation
  if ($op -eq 'open') {
    Write-Host "Opening Managed Volume: $mvLabel on $clusterIP"
    try {
      Open-MV-CDM -mvID $mvID | Out-Null
      Write-Host "Opened Managed Volume: $mvLabel for writing." -ForegroundColor Green
    } catch {
      Write-Error "Error opening Managed Volume: $mvLabel"
      Write-Error "$($_.Exception.Message)"
      $responseBody = $_.ErrorDetails.Message
      if (-not [string]::IsNullOrEmpty($responseBody)) {
        Write-Error "API response: $responseBody"
      }
      Remove-RubrikSession
      if ($logging) { Stop-Transcript }
      exit 1
    }
  } elseif ($op -eq 'close') {
    Write-Host "Closing Managed Volume: $mvLabel on $clusterIP"
    try {
      Close-MV-CDM -mvID $mvID | Out-Null
      Write-Host "Closed Managed Volume: $mvLabel to read-only." -ForegroundColor Green
    } catch {
      Write-Error "Error closing Managed Volume: $mvLabel"
      Write-Error "$($_.Exception.Message)"
      $responseBody = $_.ErrorDetails.Message
      if (-not [string]::IsNullOrEmpty($responseBody)) {
        Write-Error "API response: $responseBody"
      }
      Remove-RubrikSession
      if ($logging) { Stop-Transcript }
      exit 1
    }
  }

  # Clean up CDM session
  Remove-RubrikSession

} else {
  ### RSC MODE ###

  # Resolve MV ID if not provided directly
  if ([string]::IsNullOrEmpty($mvID)) {
    if ([string]::IsNullOrEmpty($mvName)) {
      Write-Error "No -mvID or -mvName provided. Provide either -mvID or -mvName with -clusterName."
      if ($logging) { Stop-Transcript }
      exit 1
    }
    if ([string]::IsNullOrEmpty($clusterName)) {
      Write-Error "No -clusterName provided. When using -mvName in RSC mode, also provide -clusterName."
      if ($logging) { Stop-Transcript }
      exit 1
    }
    # Look up the cluster ID
    Write-Host "Looking up cluster: $clusterName"
    $clusterResult = Find-Cluster -clusterName $clusterName
    if ($null -eq $clusterResult) {
      Write-Error "No cluster found with name: $clusterName"
      if ($logging) { Stop-Transcript }
      exit 1
    }
    $clusterID = $clusterResult.id
    Write-Host "Found cluster: $clusterName ($clusterID)"
    # Look up the MV ID
    Write-Host "Looking up Managed Volume: $mvName"
    $mvResult = Find-ManagedVolume -mvName $mvName -clusterID $clusterID
    if ($null -eq $mvResult) {
      Write-Error "No Managed Volume found with name: $mvName on cluster: $clusterName"
      if ($logging) { Stop-Transcript }
      exit 1
    }
    $mvID = $mvResult.id
    Write-Host "Found Managed Volume: $mvName ($mvID)"
  }

  # Update display label now that mvID is resolved
  $mvLabel = if (-not [string]::IsNullOrEmpty($mvName)) { "$mvName ($mvID)" } else { $mvID }

  # Execute the open or close operation
  if ($op -eq 'open') {
    Write-Host "Opening Managed Volume: $mvLabel"
    try {
      $response = Open-MV -mvID $mvID
      if ($null -eq $response.errors) {
        Write-Host "Opened Managed Volume: $mvLabel for writing." -ForegroundColor Green
      } else {
        Write-Error "Error opening Managed Volume: $mvLabel"
        Write-Error "$($response.errors.message)"
        if ($logging) { Stop-Transcript }
        exit 1
      }
    } catch {
      Write-Error "Error opening Managed Volume: $mvLabel"
      Write-Error "$($_.Exception.Message)"
      if ($logging) { Stop-Transcript }
      exit 1
    }
  } elseif ($op -eq 'close') {
    Write-Host "Closing Managed Volume: $mvLabel"
    try {
      $response = Close-MV -mvID $mvID
      if ($null -eq $response.errors) {
        Write-Host "Closed Managed Volume: $mvLabel to read-only." -ForegroundColor Green
      } else {
        Write-Error "Error closing Managed Volume: $mvLabel"
        Write-Error "$($response.errors.message)"
        if ($logging) { Stop-Transcript }
        exit 1
      }
    } catch {
      Write-Error "Error closing Managed Volume: $mvLabel"
      Write-Error "$($_.Exception.Message)"
      if ($logging) { Stop-Transcript }
      exit 1
    }
  }
}

$endTimePST = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $pstZone)
$duration = $endTimePST - $startTimePST
Write-Host "Script end time (PST): $($endTimePST.ToString('yyyy-MM-dd HH:mm:ss')) (duration: $($duration.TotalSeconds.ToString('F1'))s)"

# Stop logging
if ($logging) {
  Stop-Transcript
}
